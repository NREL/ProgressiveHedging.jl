
#### Abstract Types ####

"""
Abstract type for ProgressiveHedging penalty parameter.

Concrete subtypes determine how this penalty is used within the PH algorithm.

All concrete subtypes must implement the following methods:
* `get_penalty_value(r::<ConcreteSubtype>, xhid::XhatID)::Float64`
* `is_initial_value_dependent(::Type{<ConcreteSubtype>})::Bool`
* `is_subproblem_dependent(::Type{<ConcreteSubtype>})::Bool`
* `is_variable_dependent(::Type{<ConcreateSubtype>})::Bool`

If `is_initial_value_dependent` returns `true`, then the concrete subtype must implement
* `process_penalty_initial_value(r::<ConcreteSubtype>, ph_data::PHData)::Nothing`

If `is_subproblem_dependent` returns `true`, then the concrete subtype must implement
* `process_penalty_subproblem(r::<ConcreteSubtype>, ph_data::PHData, scenario::ScenarioID, penalties::Dict{VariableID,Float64})::Nothing`
Additionally, the concrete subproblem type must implement the function
* `report_penalty_info(as::AbstractSubproblem, pp<:AbstractPenaltyParameter)::Dict{VariableID,Float64}`

If `is_variable_dependent` returns `true`, then the concrete subtype must implement
* `penalty_map(r::<ConcreteSubtype>)::Dict{XhatID,Float64}`
If `is_variable_dependent` returns `false`, then the concrete subtype must implement
* `get_penalty_value(r::<ConcreteSubtype>)::Float64`

For more details, see the help on the individual functions.
"""
abstract type AbstractPenaltyParameter end

"""
Returns the constant penalty parameter value. Only required if `is_variable_dependent` returns false.
"""
function get_penalty_value(r::AbstractPenaltyParameter)::Float64
    throw(UnimplementedError("get_penalty_value is unimplemented for penalty parameter of type $(typeof(r))."))
end

"""
Returns the penalty value for the consensus variable associated with `xhid`.
"""
function get_penalty_value(r::AbstractPenaltyParameter,
                           xhid::XhatID
                           )::Float64
    throw(UnimplementedError("get_penalty_value is unimplemented for penalty parameter of type $(typeof(r))."))
end

"""
Returns true if the penalty parameter value is dependent on the initial solutions of the subproblems.
"""
function is_initial_value_dependent(::Type{AbstractPenaltyParameter})::Bool
    throw(UnimplementedError("is_initial_value_dependent is unimplemented for penalty parameter of type $(typeof(r))."))
end

"""
Returns true if the penalty parameter value is dependent on any data or values in the subproblems (e.g., the coefficients in the objective function).
"""
function is_subproblem_dependent(::Type{AbstractPenaltyParameter})::Bool
    throw(UnimplementedError("is_subproblem_dependent is unimplemented for penalty parameter of type $(typeof(r))."))
end

"""
Returns true if the penalty parameter value may differ for different consensus variables.
"""
function is_variable_dependent(::Type{AbstractPenaltyParameter})::Bool
    throw(UnimplementedError("is_variable_dependent is unimplemented for penalty parameter of type $(typeof(r))."))
end

"""
Returns a mapping of consensus variable ids to penalty parameter values.

Only required if `is_variable_dependent` returns false.
"""
function penalty_map(r::AbstractPenaltyParameter)::Dict{XhatID,Float64}
    throw(UnimplementedError("penalty_map is unimplemented for penalty parameter of type $(typeof(r))."))
end

"""
Performs any computations for the penalty parameter based on the initial solutions of the subproblems.

**Arguments**
*`r::AbstractPenaltyParameter` : penalty parameter struct (replace with appropriate type)
*`phd::PHData` : PH data structure used for obtaining any required variable values. See help on `PHData` for details on available functions.
"""
function process_penalty_initial_value(r::AbstractPenaltyParameter,
                                       phd,
                                       )::Nothing
    throw(UnimplementedError("process_penalty_initial_value is unimplemented for penalty parameter of type $(typeof(r))."))
end

"""
Performs any computations for the penalty parameter based data or values from the subproblems.

This function is called *before* the initial solution of subproblems. Any accessing of variable values in this function may result in undefined behavior.

**Arguments**

* `r::AbstractPenaltyParameter` : penalty parameter struct (replace with appropriate type)
* `phd::PHData` : PH data structure used for obtaining any values or information not provided by `scid` and `subproblem_dict`
* `scid::ScenarioID` : scenario id from which `subproblem_dict` comes
* `subproblem_dict::Dict{VariableID,Float64}` : Mapping specifying a value needed from a subproblem used in the computation of the penalty parameter.
"""
function process_penalty_subproblem(r::AbstractPenaltyParameter,
                                    phd,
                                    scid::ScenarioID,
                                    subproblem_dict::Dict{VariableID,Float64}
                                    )::Nothing
    throw(UnimplementedError("process_penalty_subproblem is unimplemented for penalty parameter of type $(typeof(r))."))
end

#### Concrete Types (Alphabetical Order) ####

"""
Variable dependent penalty parameter given by `k * c_i` where `c_i` is the linear coefficient of variable `i` in the objective function.  If `c_i == 0` (that is, the variable has no linear coefficient in the objective function), then the penalty value is taken to be `k`.

Requires subproblem type to have implemented `report_penalty_info` for this type. This implementation should return the linear coefficient in the objective function for each variable.
"""
struct ProportionalPenaltyParameter <: AbstractPenaltyParameter
    constant::Float64
    penalties::Dict{XhatID,Float64}
end

function ProportionalPenaltyParameter(constant::Real)
    return ProportionalPenaltyParameter(constant, Dict{XhatID,Float64}())
end

function get_penalty_value(r::ProportionalPenaltyParameter,
                           xhid::XhatID,
                           )::Float64
    return r.penalties[xhid]
end

function penalty_map(r::ProportionalPenaltyParameter)::Dict{XhatID,Float64}
    return r.penalties
end

function process_penalty_subproblem(r::ProportionalPenaltyParameter,
                                    phd,
                                    scid::ScenarioID,
                                    penalties::Dict{VariableID,Float64}
                                    )::Nothing

    for (vid, penalty) in pairs(penalties)

        xhid = convert_to_xhat_id(phd, vid)
        r_value = penalty == 0.0 ? r.constant : abs(penalty) * r.constant

        if haskey(r.penalties, xhid)
            if !isapprox(r.penalties[xhid], r_value)
                error("Penalty parameter must match across scenarios.")
            end
        else
            r.penalties[xhid] = r_value
        end

    end

    return
end

function is_initial_value_dependent(::Type{ProportionalPenaltyParameter})::Bool
    return false
end

function is_subproblem_dependent(::Type{ProportionalPenaltyParameter})::Bool
    return true
end

function is_variable_dependent(::Type{ProportionalPenaltyParameter})::Bool
    return true
end

"""
Constant scalar penalty parameter.
"""
struct ScalarPenaltyParameter <: AbstractPenaltyParameter
    value::Float64
end

function get_penalty_value(r::ScalarPenaltyParameter)::Float64
    return r.value
end

function get_penalty_value(r::ScalarPenaltyParameter,
                           xhid::XhatID,
                           )::Float64
    return get_penalty_value(r)
end

function is_initial_value_dependent(::Type{ScalarPenaltyParameter})::Bool
    return false
end

function is_subproblem_dependent(::Type{ScalarPenaltyParameter})::Bool
    return false
end

function is_variable_dependent(::Type{ScalarPenaltyParameter})::Bool
    return false
end

"""
Penalty parameter set with Watson-Woodruff SEP method. See (Watson and Woodruff 2011) for more details.

Requires subproblem type to have implemented `report_penalty_info` for this type. This implementation should return the linear coefficient in the objective function for each variable.
"""

struct SEPPenaltyParameter <: AbstractPenaltyParameter
    default::Float64
    penalties::Dict{XhatID,Float64}
end

function SEPPenaltyParameter(default::Float64=1.0)
    return SEPPenaltyParameter(default, Dict{XhatID,Float64}())
end

function get_penalty_value(r::SEPPenaltyParameter,
                           xhid::XhatID,
                           )::Float64
    return r.penalties[xhid]
end

function penalty_map(r::SEPPenaltyParameter)::Dict{XhatID,Float64}
    return r.penalties
end

function is_initial_value_dependent(::Type{SEPPenaltyParameter})::Bool
    return true
end

function process_penalty_initial_value(r::SEPPenaltyParameter,
                                       phd,
                                       )::Nothing

    for (xhid, xhat) in pairs(ph_variables(phd))

        if is_integer(xhat)

            xmin = typemax(Int)
            xmax = typemin(Int)

            for vid in variables(xhat)

                xs = branch_value(phd, vid)

                if xs < xmin
                    xmin = xs
                end

                if xs > xmax
                    xmax = xs
                end

            end

            denom = xmax - xmin + 1

        else

            denom = 0.0

            for vid in variables(xhat)
                p = probability(phd, scenario(vid))
                xs = branch_value(phd, vid)
                denom += p * abs(xs - value(xhat))
            end

            denom = max(denom, 1.0)

        end

        obj_coeff = r.penalties[xhid]
        r.penalties[xhid] = obj_coeff == 0.0 ? r.default : abs(obj_coeff)/denom

    end

    return
end

function is_subproblem_dependent(::Type{SEPPenaltyParameter})::Bool
    return true
end

function process_penalty_subproblem(r::SEPPenaltyParameter,
                                    phd,
                                    scid::ScenarioID,
                                    penalties::Dict{VariableID,Float64}
                                    )::Nothing

    for (vid, penalty) in pairs(penalties)

        xhid = convert_to_xhat_id(phd, vid)

        if haskey(r.penalties, xhid)
            if !isapprox(r.penalties[xhid], penalty)
                error("Penalty parameter must match across scenarios.")
            end
        else
            r.penalties[xhid] = penalty
        end

    end

    return
end

function is_variable_dependent(::Type{SEPPenaltyParameter})::Bool
    return true
end
