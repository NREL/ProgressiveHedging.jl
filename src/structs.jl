
struct Indexer
    next_index::Dict{NodeID, Index}
    indices::Dict{NodeID, Dict{String, Index}}
end

function Indexer()::Indexer
    idxr = Indexer(Dict{NodeID, Index}(),
                   Dict{NodeID, Dict{String,Index}}())
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

function index(idxr::Indexer, nid::NodeID, name::String)::Index

    if !haskey(idxr.indices, nid)
        idxr.indices[nid] = Dict{String, Index}()
    end
    node_vars = idxr.indices[nid]

    if haskey(node_vars, name)

        idx = node_vars[name]

    else

        idx = _retrieve_and_advance_index(idxr, nid)
        node_vars[name] = idx

    end

    return idx
end

mutable struct VariableInfo
    name::String
    node_id::NodeID
    value::Float64
end

function VariableInfo(name::String,
                      nid::NodeID
                      )::VariableInfo
    return VariableInfo(name, nid, 0.0)
end

function id(vinfo::VariableInfo)::VariableID
    return vinfo.id
end

function value(vinfo::VariableInfo)::Float64
    return vinfo.value
end

mutable struct HatVariable
    value::Float64 # Current value of variable
    vars::Set{VariableID} # All nonhat variable ids that contribute to this variable
end

HatVariable()::HatVariable = HatVariable(0.0, Set{VariableID}())
HatVariable(val::Float64, vid::VariableID) = HatVariable(val, Set{VariableID}([vid]))

function value(a::HatVariable)::Float64
    return a.value
end

function set_value(a::HatVariable, v::Float64)::Nothing
    a.value = v
    return
end

function add_variable(a::HatVariable, vid::VariableID)
    push!(a.vars, vid)
    return
end

function variables(a::HatVariable)::Set{VariableID}
    return a.vars
end

struct ScenarioInfo
    proc::Int
    prob::Float64
    subproblem::Future
    branch_vars::Dict{VariableID, VariableInfo}
    leaf_vars::Dict{VariableID, VariableInfo}
    w_vars::Dict{VariableID, Float64}
    xhat_vars::Dict{VariableID, Float64}
end

function ScenarioInfo(proc::Int,
                      prob::Float64,
                      subproblem::Future,
                      branch_map::Dict{VariableID, VariableInfo},
                      leaf_map::Dict{VariableID, VariableInfo}
                      )::ScenarioInfo

    w_dict = Dict{VariableID, Float64}(vid => 0.0 for vid in keys(branch_map))
    x_dict = Dict{VariableID, Float64}(vid => 0.0 for vid in keys(branch_map))

    return ScenarioInfo(proc,
                        prob,
                        subproblem,
                        branch_map,
                        leaf_map,
                        w_dict,
                        x_dict)
end

function create_ph_dicts(sinfo::ScenarioInfo)
    return (sinfo.w_vars, sinfo.xhat_vars)
end

function retrieve_variable(sinfo::ScenarioInfo, vid::VariableID)::VariableInfo
    if haskey(sinfo.branch_vars, vid)
        vi = sinfo.branch_vars[vid]
    else
        vi = sinfo.leaf_vars[vid]
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
    xhat::Dict{XhatID, HatVariable}
    indexer::Indexer
    residual_info::PHResidualHistory
    time_info::TimerOutputs.TimerOutput
end

function PHData(r::Real,
                tree::ScenarioTree,
                scen_proc_map::Dict{ScenarioID, Int},
                probs::Dict{ScenarioID, Float64},
                subproblems::Dict{ScenarioID, Future},
                var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}},
                time_out::TimerOutputs.TimerOutput
                )::PHData

    xhat_dict = Dict{XhatID, HatVariable}()
    idxr = Indexer()

    scenario_map = Dict{ScenarioID, ScenarioInfo}()
    for (scid, model) in pairs(subproblems)

        leaf_map = Dict{VariableID, VariableInfo}()
        branch_map = Dict{VariableID, VariableInfo}()
        for (vid, vinfo) in pairs(var_map[scid])

            if is_leaf(tree, vinfo.node_id)
                leaf_map[vid] = vinfo
            else
                branch_map[vid] = vinfo

                nid = vinfo.node_id
                idx = index(idxr, nid, vinfo.name)
                xhid = XhatID(nid, idx)

                if !haskey(xhat_dict, xhid)
                    xhat_dict[xhid] = HatVariable()
                end
                add_variable(xhat_dict[xhid], vid)

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
                  idxr,
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

function convert_to_variable_ids(phd::PHData, xid::XhatID)
    return variables(phd.xhat[xid])
end

function convert_to_xhat_id(phd::PHData, vid::VariableID)::XhatID
    vinfo = retrieve_variable(phd.scenario_map[scenario(vid)], vid)
    idx = index(phd.indexer, vinfo.node_id, vinfo.name)
    return XhatID(vinfo.node_id, idx)
end
