
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


#### Concrete Types (Alphabetical Order) ####

"""
Variable dependent penalty parameter given by `k * c_i` where `c_i` is the linear coefficient of variable `i` in the objective function.  If `c_i == 0` (that is, the variable has no linear coefficient in the objective function), then the penalty value is taken to be `k`.

Requires subproblem type to have implemented `report_penalty_info` for this type. This implementation should return the linear coefficient in the objective function for each variable.
"""
struct ProportionalPenaltyParameter <: AbstractPenaltyParameter
    constant::Float64
    penalties::Dict{XhatID,Float64}
end

"""
Constant scalar penalty parameter.
"""
struct ScalarPenaltyParameter <: AbstractPenaltyParameter
    value::Float64
end

"""
Penalty parameter set with Watson-Woodruff SEP method. See (Watson and Woodruff 2011) for more details.

Requires subproblem type to have implemented `report_penalty_info` for this type. This implementation should return the linear coefficient in the objective function for each variable.
"""
struct SEPPenaltyParameter <: AbstractPenaltyParameter
    default::Float64
    penalties::Dict{XhatID,Float64}
end
