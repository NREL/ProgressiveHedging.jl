
include("id_types.jl")
include("scenario_tree.jl")

struct Indexer
    next_index::Dict{NodeID, Index}
    indices::Dict{NodeID, Set{Index}}
end

function Indexer()::Indexer
    idxr = Indexer(Dict{NodeID, Index}(),
                   Dict{NodeID, Set{Index}}())
    return idxr
end

function _retrieve_and_advance_index(idxr::Indexer, nid::NodeID)::Index
    if !haskey(idxr.next_index, nid)
        idxr.next_index[nid] = Index(zero(INDEX))
    end
    idx = idxr.next_index[nid]
    idxr.next_index[nid] = _increment(idx)
    return idx
end

function next_index(idxr::Indexer, node::ScenarioNode)::Index
    nid = id(node)
    nidx = _retrieve_and_advance_index(idxr, nid)
    if !haskey(idxr.indices, nid)
        idxr.indices[nid] = Set{Index}()
    end
    push!(idxr.indices[nid], nidx)
    return nidx
end

function indices(idxr::Indexer, node::ScenarioNode)::Set{Index}
    return idxr.indices[id(node)]
end

mutable struct VariableInfo
    ref::Union{Future,JuMP.VariableRef}
    name::String
    node_id::NodeID
    value::Float64
end

function VariableInfo(ref::Union{Future,JuMP.VariableRef},
                      name::String,
                      nid::NodeID
                      )::VariableInfo
    return VariableInfo(ref, name, nid, 0.0)
end

mutable struct PHVariable
    ref::Union{Future,Nothing}
    value::Float64
end

PHVariable()::PHVariable = PHVariable(nothing, 0.0)

mutable struct PHHatVariable
    value::Float64
end

PHHatVariable()::PHHatVariable = PHHatVariable(0.0)

function value(a::PHHatVariable)::Float64
    return a.value
end

struct ScenarioInfo
    proc::Int
    prob::Float64
    model::Future
    branch_map::Dict{VariableID, VariableInfo}
    leaf_map::Dict{VariableID, VariableInfo}
    W::Dict{VariableID, PHVariable}
    Xhat::Dict{XhatID, PHVariable}
end

function ScenarioInfo(proc::Int, prob::Float64, submodel::Future,
                      branch_map::Dict{VariableID, VariableInfo},
                      leaf_map::Dict{VariableID, VariableInfo}
                      )::ScenarioInfo

    w_dict = Dict{VariableID, PHVariable}(vid => PHVariable()
                                          for vid in keys(branch_map))

    x_dict = Dict{XhatID, PHVariable}()
    for (vid,vinfo) in pairs(branch_map)
        x_dict[XhatID(vinfo.node_id, vid.index)] = PHVariable()
    end

    return ScenarioInfo(proc,
                        prob,
                        submodel,
                        branch_map,
                        leaf_map,
                        w_dict,
                        x_dict)
end

function retrieve_variable(sinfo::ScenarioInfo, vid::VariableID)::VariableInfo
    if haskey(sinfo.branch_map, vid)
        vi = sinfo.branch_map[vid]
    else
        vi = sinfo.leaf_map[vid]
    end
    return vi
end

struct PHResidualHistory
    residuals::Dict{Int,Float64}
end

function PHResidualHistory()::PHResidualHistory
    return PHResidualHistory(Dict{Int,Float64}())
end

function residual_vector(phrh::PHResidualHistory)::Vector{Float64}
    if length(phrh.residuals) > 0
        max_iter = maximum(keys(phrh.residuals))
        return [phrh.residuals[k] for k in sort!(collect(keys(phrh.residuals)))]
    else
        return Vector{Float64}()
    end
end

function save_residual(phrh::PHResidualHistory, iter::Int, res::Float64)::Nothing
    @assert(!(iter in keys(phrh.residuals)))
    phrh.residuals[iter] = res
    return
end

struct PHData
    r::Float64
    scenario_tree::ScenarioTree
    scenario_map::Dict{ScenarioID, ScenarioInfo}
    Xhat::Dict{XhatID, PHHatVariable}
    indexer::Indexer
    residual_info::PHResidualHistory
    time_info::TimerOutputs.TimerOutput
end

function PHData(r::N, tree::ScenarioTree,
                scen_proc_map::Dict{ScenarioID, Int},
                probs::Dict{ScenarioID, Float64},
                submodels::Dict{ScenarioID, Future},
                var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}},
                indexer::Indexer,
                time_out::TimerOutputs.TimerOutput
                )::PHData where {N <: Number}

    xhat_dict = Dict{XhatID, PHHatVariable}()

    scenario_map = Dict{ScenarioID, ScenarioInfo}()
    for (scid, model) in pairs(submodels)

        leaf_map = Dict{VariableID, VariableInfo}()
        branch_map = Dict{VariableID, VariableInfo}()
        for (vid, vinfo) in var_map[scid]

            if is_leaf(tree, vinfo.node_id)
                leaf_map[vid] = vinfo
            else
                branch_map[vid] = vinfo

                xid = XhatID(vinfo.node_id, vid.index)
                if !haskey(xhat_dict, xid)
                    xhat_dict[xid] = PHHatVariable()
                end
            end

        end

        scenario_map[scid] = ScenarioInfo(scen_proc_map[scid],
                                          probs[scid],
                                          model,
                                          branch_map,
                                          leaf_map,
                                          )

    end

    return PHData(float(r),
                  tree,
                  scenario_map,
                  xhat_dict,
                  indexer,
                  PHResidualHistory(),
                  time_out,
                  )
end

function residuals(phd::PHData)::Vector{Float64}
    return residual_vector(phd.residual_info)
end

function save_residual(phd::PHData, iter::Int, res::Float64)::Nothing
    save_residual(phd.residual_info, iter, res)
    return
end

function stage_id(phd::PHData, xid::XhatID)::StageID
    return phd.scenario_tree.tree_map[xid.node].stage
end

function scenario_bundle(phd::PHData, xid::XhatID)::Set{ScenarioID}
    return scenario_bundle(phd.scenario_tree, xid.node)
end

function convert_to_variable_id(phd::PHData, xid::XhatID)
    idx = xid.index
    stage = stage_id(phd, xid)
    scen = first(scenario_bundle(phd, xid))
    return (scen, VariableID(stage, idx))
end

function convert_to_xhat_id(phd::PHData, scid::ScenarioID, vid::VariableID)::XhatID
    vinfo = retrieve_variable(phd.scenario_map[scid], vid)
    return XhatID(vinfo.node_id, vid.index)
end
