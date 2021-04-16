
# Functions separated from type definitions for compiler reasons

#### Abstract Interface Functions ####

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
                                       phd::PHData,
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
                                    phd::PHData,
                                    scid::ScenarioID,
                                    subproblem_dict::Dict{VariableID,Float64}
                                    )::Nothing
    throw(UnimplementedError("process_penalty_subproblem is unimplemented for penalty parameter of type $(typeof(r))."))
end

#### Concrete Implementations ####

## Proportional Penalty Parameter ##

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
                                    phd::PHData,
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

## Scalar Penalty Parameter ##

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

## SEP Penalty Parameter ##

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
                                       phd::PHData,
                                       )::Nothing

    for (xhid, xhat) in pairs(consensus_variables(phd))

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
                                    phd::PHData,
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
