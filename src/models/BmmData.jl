using DataFrames
using LinearAlgebra
using NearestNeighbors
using Statistics

mutable struct BmmData

    # Static data
    x::DataFrame;
    position_data::Array{Float64, 2};
    composition_data::Array{Int, 1};
    confidence::Array{Float64, 1}

    adjacent_points::Array{Array{Int, 1}, 1};
    adjacent_weights::Array{Array{Float64, 1}, 1};
    real_edge_weight::Float64;
    position_knn_tree::KDTree;
    knn_neighbors::Array{Array{Int, 1}, 1};

    # Distribution-related
    components::Array{Component, 1};
    distribution_sampler::Component;
    assignment::Array{Int, 1};

    noise_density::Float64;

    gene_probs_given_single_transcript::Array{Float64, 2};

    # Utils
    tracer::Dict{String, Any};

    # Parameters
    update_priors::Symbol;

    """
    ...
    # Arguments
    - `components::Array{Component, 1}`:
    - `x::DataFrame`:
    - `adjacent_points::Array{Array{Int, 1}, 1}`:
    - `adjacent_weights::Array{Array{Float64, 1}, 1}`: edge weights, used for smoothness penalty
    - `real_edge_weight::Float64`: weight of an edge for "average" real point
    - `distribution_sampler::Component`:
    - `assignment::Array{Int, 1}`:
    - `k_neighbors::Int=20`:
    - `update_priors::Symbol=:no`: method of prior updates. Possible values: `:no` (no update), `:all` (use all distribitions) and `:centers` (only use distributions, based on prior centers)
    """
    function BmmData(components::Array{Component, 1}, x::DataFrame, adjacent_points::Array{Array{Int, 1}, 1},
                     adjacent_weights::Array{Array{Float64, 1}, 1}, real_edge_weight::Float64, distribution_sampler::Component,
                     assignment::Array{Int, 1}; k_neighbors::Int=20, update_priors::Symbol=:no)
        @assert maximum(assignment) <= length(components)
        @assert minimum(assignment) >= 0
        @assert length(assignment) == size(x, 1)

        if !all(s in names(x) for s in [:x, :y, :gene])
            error("`x` data frame must have columns 'x', 'y' and 'gene'")
        end

        p_data = position_data(x)
        position_knn_tree = KDTree(p_data)
        knn_neighbors = knn(position_knn_tree, p_data, k_neighbors)[1]

        n_genes = maximum(composition_data(x))

        if update_priors == :centers && all(c.can_be_dropped for c in components)
            update_priors = :no
        end

        x = deepcopy(x)
        if !(:confidence in names(x))
            x[:confidence] = 0.95
        end

        self = new(x, p_data, composition_data(x), confidence(x), adjacent_points, adjacent_weights, real_edge_weight,
                   position_knn_tree, knn_neighbors, components, deepcopy(distribution_sampler), assignment,
                   0.0, ones(n_genes, n_genes) ./ n_genes, Dict{String, Any}(), update_priors)

        for c in self.components
            c.n_samples = 0
        end

        for c_id in assignment[assignment .> 0]
            self.components[c_id].n_samples += 1
        end

        return self
    end
end

position_data(df::AbstractDataFrame)::Array{Float64, 2} = Matrix{Float64}(df[:, [:x, :y]])'
position_data(data::BmmData)::Array{Float64, 2} = data.position_data
composition_data(df::AbstractDataFrame)::Array{Int, 1} = df[!, :gene]
composition_data(data::BmmData)::Array{Int, 1} = data.composition_data
confidence(df::AbstractDataFrame)::Array{Float64, 1} = df[!, :confidence]
confidence(data::BmmData)::Array{Float64, 1} = data.confidence

num_of_molecules_per_cell(data::BmmData) = count_array(data.assignment .+ 1, max_value=length(data.components) + 1)[2:end]

function assign!(data::BmmData, point_ind::Int, component_id::Int)
    @assert component_id <= length(data.components) "Too large component id: $component_id, maximum available: $(length(data.components))"
    data.assignment[point_ind] = component_id
end

function merge_bm_data(bmm_data_arr::Array{BmmData, 1})
    @assert length(bmm_data_arr) > 0

    x = vcat([deepcopy(bd.x) for bd in bmm_data_arr]...)
    components = vcat([deepcopy(bd.components) for bd in bmm_data_arr]...)

    adjacent_points = Array{Int64,1}[]
    adjacent_weights = Array{Float64,1}[]
    ap_offset = 0;
    for bd in bmm_data_arr
        append!(adjacent_points, [deepcopy(ap) .+ ap_offset for ap in bd.adjacent_points])
        append!(adjacent_weights, deepcopy(bd.adjacent_weights))
        ap_offset += size(bd.x, 1)
    end

    assignments = Array{Int64,1}[]
    assignment_offset = 0;
    for bd in bmm_data_arr
        cur_assignment = deepcopy(bd.assignment) .+ assignment_offset
        cur_assignment[bd.assignment .== 0] .= 0
        push!(assignments, cur_assignment)
        assignment_offset += length(bd.components)
    end

    k_neighbors=length(bmm_data_arr[1].knn_neighbors[1])

    res = BmmData(components, x, adjacent_points, adjacent_weights, bmm_data_arr[1].real_edge_weight,
        deepcopy(bmm_data_arr[1].distribution_sampler), vcat(assignments...); k_neighbors=k_neighbors,
        update_priors=bmm_data_arr[1].update_priors)

    res.tracer = merge_tracers([bd.tracer for bd in bmm_data_arr])

    return res
end

function get_cell_stat_df(data::BmmData; add_qc::Bool=true)
    df = DataFrame(:cell => 1:length(data.components))

    centers = hcat([c.position_params.μ for c in data.components]...)

    for s in [:x, :y]
        df[!,s] = mean.(split(data.x[!,s], data.assignment .+ 1, max_factor=length(data.components) + 1)[2:end])
    end

    df[!,:has_center] = [c.center_prior !== nothing for c in data.components]
    df[!,:x_prior], df[!,:y_prior] = [[(c.center_prior === nothing) ? NaN : c.center_prior.μ[i] for c in data.components] for i in 1:2]

    if add_qc
        segmented_df = get_segmentation_df(data);
        pos_data_per_cell = position_data.(split(segmented_df, segmented_df.cell .+ 1)[2:end]);
        df[!,:area] = area.(convex_hull.(pos_data_per_cell));

        df[!,:n_transcripts] = size.(pos_data_per_cell, 2);
        df[!,:density] = df[!,:n_transcripts] ./ df[!,:area];

        df[!,:elongation] = [x[2] / x[1] for x in eigvals.(cov.(transpose.(pos_data_per_cell)))];
    end

    return df[num_of_molecules_per_cell(data) .> 0,:]
end

function get_segmentation_df(data::BmmData, gene_names::Union{Nothing, Array{String, 1}}=nothing)
    df = deepcopy(data.x)
    df[!,:cell] = deepcopy(data.assignment);
    df[!,:is_noise] = (data.assignment .== 0);

    if gene_names !== nothing
        df[!,:gene] = gene_names[df[!,:gene]]
    end

    return df
end