
#### Abstract Types ####

"""
Abstract type for ProgressiveHedging penalty parameter.

Concrete sybtypes determine how this penalty is used within the PH algorithm.

All concrete subtypes must implement the following methods:
* `get_penalty_value(r::<ConcreteSubtype>, xhid::XhatID)::Float64`
* `is_initial_value_dependent(::Type{<ConcreteSubtype>})::Bool`
* `is_subproblem_dependent(::Type{<ConcreteSubtype>})::Bool`
* `is_variable_dependent(::Type{<ConcreateSubtype>})::Bool`
"""
abstract type AbstractPenaltyParameter end

# TODO: Document these functions

function get_penalty_value(r::AbstractPenaltyParameter)::Float64
    throw(UnimplementedError("get_penalty_value is unimplemented for penalty parameter of type $(typeof(r))."))
end

function get_penalty_value(r::AbstractPenaltyParameter,
                           xhid::XhatID
                           )::Float64
    throw(UnimplementedError("get_penalty_value is unimplemented for penalty parameter of type $(typeof(r))."))
end

function is_initial_value_dependent(::Type{AbstractPenaltyParameter})::Bool
    throw(UnimplementedError("is_initial_value_dependent is unimplemented for penalty parameter of type $(typeof(r))."))
end

function is_subproblem_dependent(::Type{AbstractPenaltyParameter})::Bool
    throw(UnimplementedError("is_subproblem_dependent is unimplemented for penalty parameter of type $(typeof(r))."))
end

function is_variable_dependent(::Type{AbstractPenaltyParameter})::Bool
    throw(UnimplementedError("is_variable_dependent is unimplemented for penalty parameter of type $(typeof(r))."))
end

function penalty_map(r::AbstractPenaltyParameter)::Dict{XhatID,Float64}
    throw(UnimplementedError("penalty_map is unimplemented for penalty parameter of type $(typeof(r))."))
end

function process_penalty_initial_value(r::AbstractPenaltyParameter,
                                       phd,
                                       )::Nothing
    throw(UnimplementedError("process_penalty_initial_value is unimplemented for penalty parameter of type $(typeof(r))."))
end

function process_penalty_subproblem(r::AbstractPenaltyParameter,
                                    phd,
                                    scid::ScenarioID,
                                    subproblem_dict::Dict{VariableID,Float64}
                                    )::Nothing
    throw(UnimplementedError("process_penalty_subproblem is unimplemented for penalty parameter of type $(typeof(r))."))
end

#### Concrete Types (Alphabetical Order) ####

"""
Variable dependent penalty parameter given by `k * c_i` where `c_i` is the linear coefficient of variable `i` in the objective function.
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

        if haskey(r.penalties, xhid)
            if !isapprox(r.penalties[xhid], penalty * r.constant)
                error("Penalty parameter must match across scenarios.")
            end
        else
            r.penalties[xhid] = penalty * r.constant
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
Penalty parameter set with Watson-Woodruff heuristic TODO: put paper reference, add default
"""

struct SEPPenaltyParameter <: AbstractPenaltyParameter
    penalties::Dict{XhatID,Float64}
end

function SEPPenaltyParameter()
    return SEPPenaltyParameter(Dict{XhatID,Float64}())
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

        r.penalties[xhid] = r.penalties[xhid]/denom

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
