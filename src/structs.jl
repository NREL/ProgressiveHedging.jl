
struct ModelInfo{K}
    id::String
    stage::Int
    scen_bundle::Set{K}
end

struct PHInitInfo{K}
    scenarios::Set{K}
    leaves::Dict{K,StructJuMP.StructuredModel}
    node_map::Dict{StructJuMP.StructuredModel, ModelInfo{K}}
end

struct VariableInfo{K}
    stage::Int
    scenario_bundle::Set{K}
    sj_model::StructJuMP.StructuredModel
end

struct PHParams{K}
    r::Float64
    scenarios::Set{K}
    probs::Dict{K,Float64}
    variable_map::Dict{String, VariableInfo{K}}
end

struct PHData{K, M <: JuMP.AbstractModel}
    init::PHInitInfo{K}
    params::PHParams{K}
    submodels::Dict{K,M}
    W::Dict{Tuple{K,String}, Float64}
    Xhat::Dict{Tuple{K,String}, Float64}
end

function PHData(phii::PHInitInfo{K}, php::PHParams{K}, submodels::Dict{K,M}
                ) where {K, M <: JuMP.AbstractModel}
    phd = PHData(phii, php, submodels,
                 Dict{Tuple{K,String}, Float64}(),
                 Dict{Tuple{K,String}, Float64}()
                 )
    for (var, info) in pairs(phd.params.variable_map)
        for s in info.scenario_bundle
            tup = Tuple([s,var])
            phd.Xhat[tup] = 0.0
            phd.W[tup] = 0.0
        end
    end
    return phd
end

# const NODE_ID = Int

# struct ScenarioNode
#     id::NODE_ID # unique identifier
#     stage::Int # stage of this node occupies
#     scenario_bundle::Set{Int} # scenarios that are children of this node
#     parent::Union{Nothing, ScenarioNode}
#     children::Dict{NODE_ID, ScenarioNode}
# end

# struct ScenarioTree
#     root::ScenarioNode
#     map::Dict{NODE_ID, ScenarioNode}
#     next_id::NODE_ID
# end
    
