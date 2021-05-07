
#### Exceptions ####

"""
Exception indicating that the specified method is not implemented for an interface.
"""
struct UnimplementedError <: Exception
    msg::String
end

#### Internal Types and Methods ####

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

mutable struct VariableData
    name::String
    xhat_id::XhatID
end

function VariableData(name::String,
                      nid::NodeID
                      )::VariableData
    return VariableData(name, nid, 0.0)
end

mutable struct ProblemData
    obj::Float64
    sts::MOI.TerminationStatusCode
    time::Float64
end

ProblemData() = ProblemData(0.0, MOI.OPTIMIZE_NOT_CALLED, 0.0)

struct ScenarioInfo
    pid::Int
    prob::Float64
    branch_vars::Dict{VariableID, Float64}
    leaf_vars::Dict{VariableID, Float64}
    w_vars::Dict{VariableID, Float64}
    xhat_vars::Dict{VariableID, Float64}
    problem_data::ProblemData
end

function ScenarioInfo(pid::Int,
                      prob::Float64,
                      branch_ids::Set{VariableID},
                      leaf_ids::Set{VariableID}
                      )::ScenarioInfo

    branch_map = Dict{VariableID, Float64}()
    w_dict = Dict{VariableID, Float64}()
    x_dict = Dict{VariableID, Float64}()
    for vid in branch_ids
        branch_map[vid] = 0.0
        w_dict[vid] = 0.0
        x_dict[vid] = 0.0
    end

    leaf_map = Dict{VariableID, Float64}(vid => 0.0 for vid in leaf_ids)

    return ScenarioInfo(pid,
                        prob,
                        branch_map,
                        leaf_map,
                        w_dict,
                        x_dict,
                        ProblemData())
end

function create_ph_dicts(sinfo::ScenarioInfo)
    return (sinfo.w_vars, sinfo.xhat_vars)
end

function objective_value(sinfo::ScenarioInfo)::Float64
    return sinfo.problem_data.obj
end

function retrieve_variable_value(sinfo::ScenarioInfo, vid::VariableID)::Float64
    if haskey(sinfo.branch_vars, vid)
        vi = sinfo.branch_vars[vid]
    else
        vi = sinfo.leaf_vars[vid]
    end
    return vi
end

struct PHIterate
    xhat::Dict{XhatID,Float64}
    x::Dict{VariableID,Float64}
    w::Dict{VariableID,Float64}
end

struct PHIterateHistory
    iterates::Dict{Int,PHIterate}
end

function PHIterateHistory()
    return PHIterateHistory(Dict{Int,PHIterate}())
end

function _save_iterate(phih::PHIterateHistory,
                       iter::Int,
                       phi::PHIterate,
                       )::Nothing
    phih.iterates[iter] = phi
    return
end

struct PHResidual
    abs_res::Float64
    rel_res::Float64
    xhat_sq::Float64
    x_sq::Float64
end

struct PHResidualHistory
    residuals::Dict{Int,PHResidual}
end

function PHResidualHistory()::PHResidualHistory
    return PHResidualHistory(Dict{Int,PHResidual}())
end

function residual_vector(phrh::PHResidualHistory)::Vector{Float64}
    if length(phrh.residuals) > 0
        max_iter = maximum(keys(phrh.residuals))
        return [phrh.residuals[k].abs_res for k in sort!(collect(keys(phrh.residuals)))]
    else
        return Vector{Float64}()
    end
end

function relative_residual_vector(phrh::PHResidualHistory)::Vector{Float64}
    if length(phrh.residuals) > 0
        max_iter = maximum(keys(phrh.residuals))
        return [phrh.residuals[k].rel_res for k in sort!(collect(keys(phrh.residuals)))]
    else
        return Vector{Float64}()
    end
end

function residual_components(phrh::PHResidualHistory)::NTuple{2,Vector{Float64}}
    if length(phrh.residuals) > 0
        max_iter = maximum(keys(phrh.residuals))
        sorted_keys = sort!(collect(keys(phrh.residuals)))
        xhat_sq = [phrh.residuals[k].xhat_sq for k in sorted_keys]
        x_sq = [phrh.residuals[k].x_sq for k in sorted_keys]
        return (xhat_sq, x_sq)
    else
        return (Vector{Float64}(), Vector{Float64}())
    end
end

function _save_residual(phrh::PHResidualHistory, iter::Int, res::PHResidual)::Nothing
    # @assert(!(iter in keys(phrh.residuals)))
    phrh.residuals[iter] = res
    return
end

#### User Facing Types ####

"""
Struct for user callbacks.

**Fields**

* `name::String` : User's name for the callback. Defaults to `string(h)`.
* `h::Function` : Callback function. See notes below for calling signature.
* `initialize::Function` : Function to initialize `ext` *after* subproblem creation has occurred.
* `ext::Dict{Symbol,Any}` : Dictionary to store data between callback calls or needed parameters.

The callback function `h` must have the signature
    `h(ext::Dict{Symbol,Any}, phd::PHData, winf::WorkerInf, niter::Int)::Bool`
where `ext` is the same dictionary given to the `Callback` constructor, `phd` is the standard PH data structure (see `PHData`), `winf` is used for communicating with subproblems (see `apply_to_subproblem`)  and `niter` is the current iteration. The callback may return `false` to stop PH.

The `initialize` function must have the signature
    `initialize(ext::Dict{Symbol,Any}, phd::PHData)`
where `ext` is the same dictionary given to the `Callback` constructor and `phd` is the standard PH data structure (see `PHData`).
"""
struct Callback
    name::String
    h::Function
    initialize::Function
    ext::Dict{Symbol,Any}
end

function Base.show(io::IO, cb::Callback)
    print(io, cb.name)
    return
end

"""
Struct for a consensus variable.

**Fields**

*`value::Float64` : Current value of the consensus variable
*`vars::Set{VariableID}` : Individual scenario variables contributing to this consensus variable
*`is_integer::Bool` : Flag indicating that this variable is an integer (or binary)
"""
mutable struct HatVariable
    value::Float64 # Current value of variable
    vars::Set{VariableID} # All nonhat variable ids that contribute to this variable
    is_integer::Bool # Flag indicating that this variable is an integer (includes binary)
end

## Primary PH Data Structure ##

"""
Data structure used to store information and results for a stochastic programming problem.
"""
struct PHData
    r::AbstractPenaltyParameter
    scenario_tree::ScenarioTree
    scenario_map::Dict{ScenarioID, ScenarioInfo}
    callbacks::Vector{Callback}
    xhat::Dict{XhatID, HatVariable}
    variable_data::Dict{VariableID, VariableData}
    indexer::Indexer
    iterate_history::PHIterateHistory
    residual_history::PHResidualHistory
    time_info::TimerOutputs.TimerOutput
end

function PHData(r::AbstractPenaltyParameter,
                tree::ScenarioTree,
                scen_proc_map::Dict{Int, Set{ScenarioID}},
                var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}},
                time_out::TimerOutputs.TimerOutput
                )::PHData

    var_data = Dict{VariableID,VariableData}()
    xhat_dict = Dict{XhatID, HatVariable}()
    idxr = Indexer()

    scenario_map = Dict{ScenarioID, ScenarioInfo}()
    for (pid, scenarios) in pairs(scen_proc_map)
        for scen in scenarios

            branch_ids = Set{VariableID}()
            leaf_ids = Set{VariableID}()

            for (vid, vinfo) in pairs(var_map[scen])

                vnode = node(tree, vid.scenario, vid.stage)

                if vnode == nothing
                    error("Unable to locate scenario tree node for variable '$(vinfo.name)' occuring in scenario $(vid.scenario) and stage $(vid.stage).")
                end

                idx = index(idxr, vnode.id, vinfo.name)
                xhid = XhatID(vnode.id, idx)
                vdata = VariableData(vinfo.name, xhid)
                var_data[vid] = vdata

                if is_leaf(vnode)

                    push!(leaf_ids, vid)

                else

                    push!(branch_ids, vid)

                    if haskey(xhat_dict, xhid)
                        if is_integer(xhat_dict[xhid]) != vinfo.is_integer
                            error("Variable '$(vinfo.name)' must be integer or non-integer in all scenarios in which it is used.")
                        end
                    else
                        xhat_dict[xhid] = HatVariable(vinfo.is_integer)
                    end
                    add_variable(xhat_dict[xhid], vid)

                end
            end

            scenario_map[scen] = ScenarioInfo(pid,
                                              tree.prob_map[scen],
                                              branch_ids,
                                              leaf_ids,
                                              )
        end
    end

    return PHData(r,
                  tree,
                  scenario_map,
                  Vector{Callback}(),
                  xhat_dict,
                  var_data,
                  idxr,
                  PHIterateHistory(),
                  PHResidualHistory(),
                  time_out,
                  )
end

function Base.show(io::IO, phd::PHData)
    nscen = length(scenarios(phd))
    print(io, "PH structure for a stochastic program with $(nscen) scenarios.")
    return
end

#### User Facing Functions ####

## Callback Functions ##

"""
    Callback(f::Function)

Creates a `Callback` structure for function `f`.
"""
function Callback(f::Function)
    return Callback(string(f), f, (::Dict{Symbol,Any},::PHData)->(), Dict{Symbol,Any}())
end

"""
    cb(f::Function)

Shorthand for `Callback(f)`.
"""
cb(f::Function) = Callback(f)

"""
    Callback(f::Function, ext::Dict{Symbol,Any})

Creates a `Callback` structure for function `f` with the external data dictionary `ext`.
"""
function Callback(f::Function, ext::Dict{Symbol,Any})
    return Callback(string(f), f, (::Dict{Symbol,Any},::PHData)->(), ext)
end

"""
    Callback(f::Function, initialize::Function)

Creates a `Callback` structure for function `f` with initializer `initialize`.
"""
function Callback(f::Function, initialize::Function)
    return Callback(string(f), f, initialize, Dict{Symbol,Any}())
end

"""
    Callback(name::String, f::Function, ext::Dict{Symbol,Any})

Creates a `Callback` structure for function `f` with the name `name` and the external data dictionary `ext`.
"""
function Callback(name::String, f::Function, ext::Dict{Symbol,Any})
    return Callback(name, f, (::Dict{Symbol,Any},::PHData)->(), ext)
end

"""
    Callback(f::Function, initialize::Function, ext::Dict{Symbol,Any})

Creates a `Callback` structure for function `f` with the external data dictionary `ext` which will be initialized with `initialize`.
"""
function Callback(f::Function, initialize::Function, ext::Dict{Symbol,Any})
    return Callback(string(f), f, initialize, ext)
end

## Consensus Variable Functions ##

HatVariable(is_int::Bool)::HatVariable = HatVariable(0.0, Set{VariableID}(),is_int)
function HatVariable(val::Float64,vid::VariableID, is_int::Bool)
    return HatVariable(val, Set{VariableID}([vid]), is_int)
end

function is_integer(a::HatVariable)::Bool
    return a.is_integer
end

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

## PHData Interaction Functions ##

"""
    add_callback(phd::PHData,
                 cb::Callback
                 )::Nothing

Adds the callback `cb` to the given PH problem.
"""
function add_callback(phd::PHData,
                      cb::Callback
                      )::Nothing

    push!(phd.callbacks, cb)
    cb.initialize(cb.ext, phd)

    return
end

"""
    apply_to_subproblem(to_apply::Function,
                        phd::PHData,
                        winf::WorkerInf,
                        scid::ScenarioID,
                        args::Tuple=(),
                        kwargs::NamedTuple=NamedTuple(),
                        )

Applies the function `to_apply` to the subproblem with scenario id `scid`.
"""

function apply_to_subproblem(to_apply::Function,
                             phd::PHData,
                             winf::WorkerInf,
                             scid::ScenarioID,
                             args::Tuple=(),
                             kwargs::NamedTuple=NamedTuple(),
                             )

    _send_message(winf,
                  phd.scenario_map[scid].pid,
                  SubproblemAction(scid,
                                   to_apply,
                                   args,
                                   kwargs)
                  )

    return
end

"""
    consensus_variables(phd::PHData)::Dict{XhatID,HatVariable}

Returns the collection of consensus variables for the problem.
"""
function consensus_variables(phd::PHData)::Dict{XhatID,HatVariable}
    return phd.xhat
end

"""
    convert_to_variable_ids(phd::PHData, xid::XhatID)::Set{VariableID}

Convert the given consensus variable id to the contributing individual subproblem variable ids.

**Arguments**

* `phd::PHData` : PH data structure for the corresponding problem
* `xid::XhatID` : consensus variable id to convert
"""
function convert_to_variable_ids(phd::PHData, xid::XhatID)::Set{VariableID}
    return variables(phd.xhat[xid])
end

"""
    convert_to_xhat_id(phd::PHData, vid::VariableID)::XhatID

Convert the given `VariableID` to the consensus variable id (`XhatID`).

**Arguments**

* `phd::PHData` : PH data structure for the corresponding problem
* `vid::VariableID` : variable id to convert
"""
function convert_to_xhat_id(phd::PHData, vid::VariableID)::XhatID
    return phd.variable_data[vid].xhat_id
end

"""
    get_callback(phd::PHData, name::String)::Callback

Retrieve the callback with name `name`.
"""
function get_callback(phd::PHData, name::String)::Callback
    return_cb = nothing
    for cb in phd.callbacks
        if cb.name == name
            return_cb = cb
        end
    end

    if return_cb === nothing
        error("Unable to find callback $name.")
    end

    return return_cb
end

"""
    get_callback_ext(phd::PHData, name::String)::Dict{Symbol,Any}

Retrieve the external dictionary for callback `name`.
"""
function get_callback_ext(phd::PHData, name::String)::Dict{Symbol,Any}
    cb = get_callback(phd, name)
    return cb.ext
end

"""
    is_leaf(phd::PHData, xhid::XhatID)::Bool

Returns true if the given consensus variable id belongs to a leaf vertex in the scenario tree.
"""
function is_leaf(phd::PHData, xhid::XhatID)::Bool
    return is_leaf(phd.scenario_tree, xhid.node)
end

"""
    name(phd::PHData, xid::XhatID)::String

Returns the name of the consensus variable for the given `XhatID`. The name is the same given to the individual scenario variables.
"""
function name(phd::PHData, xid::XhatID)::String
    return name(phd, first(convert_to_variable_ids(phd, xid)))
end

"""
    probability(phd::PHData, scenario::ScenarioID)::Float64

Returns the probability of the given scenario.
"""
function probability(phd::PHData, scenario::ScenarioID)::Float64
    return phd.scenario_map[scenario].prob
end

"""
    residuals(phd::PHData)::Vector{Float64}

Returns the absolute residuals at the iterations specified by the user.
"""
function residuals(phd::PHData)::Vector{Float64}
    return residual_vector(phd.residual_history)
end

"""
    residual_components(phd::PHData)::NTuple{2,Vector{Float64}}

Returns the components of the absolute residual at the iterations specified by the user.
"""
function residual_components(phd::PHData)::NTuple{2,Vector{Float64}}
    return residual_components(phd.residual_history)
end

"""
    relative_residuals(phd::PHData)::Vector{Float64}

Returns the relative residuals at the iterations specified by the user.
"""
function relative_residuals(phd::PHData)::Vector{Float64}
    return relative_residual_vector(phd.residual_history)
end

"""
    scenario_bundle(phd::PHData, xid::XhatID)::Set{ScenarioID}

Returns the scenarios contributing to the consensus variable associated with `xid`.
"""
function scenario_bundle(phd::PHData, xid::XhatID)::Set{ScenarioID}
    return scenario_bundle(phd.scenario_tree, xid.node)
end

"""
    scenarios(phd::PHData)::Set{ScenarioID}

Returns the set of all scenarios for the stochastic problem.
"""
function scenarios(phd::PHData)::Set{ScenarioID}
    return scenarios(phd.scenario_tree)
end

"""
    stage_id(phd::PHData, xid::XhatID)::StageID

Returns the `StageID` in which the given consensus variable is.
"""
function stage_id(phd::PHData, xid::XhatID)::StageID
    return phd.scenario_tree.tree_map[xid.node].stage
end
