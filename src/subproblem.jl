#### PH Subproblem Interface ####

"""
Abstract type for ProgressiveHedging subproblem types.

A concrete subtype handles all details of creating, solving and updating subproblems for ProgressiveHedging (PH).  In particular, it handles all interaction with any modeling language that the subproblem is written in.  See `JuMPSubproblem` for an implementation that uses JuMP as the optimization modeling language.

Variables and their values are identified and exchanged between PH and a Subproblem type using the `VariableID` type.  A unique `VariableID` is associated with each variable in the subproblem by the Subproblem implementation by using the `ScenarioID` of the subproblem as well as the `StageID` to which this variable belongs.  This combination uniquely identifies a node in the scenario tree to which the variable can be associated.  Variables associated with the same node in a scenario tree and sharing the same name are assumed to be consensus variables whose optimal value is determined by PH.  The final component of a `VariableID` is an `Index` which is just a counter assigned to a variable to differentiate it from other variables at the same node.  See `VariableID` type for more details.

Any concrete subtype must implement the following functions:
* `add_ph_objective_terms(sp::<ConcreteSubtype>, vids::Vector{VariableID}, r::AbstractPenaltyParameter)::Dict{VariableID,Float64}`
* `objective_value(sp::<ConcreteSubtype>)::Float64`
* `report_values(sp::<ConcreteSubtype>, vars::Vector{VariableID})::Dict{VariableID,Float64}`
* `report_variable_info(sp::<ConcreteSubtype>, st::ScenarioTree)::Dict{VariableID,String}`
* `solve(sp::<ConcreteSubtype>)::MOI.TerminationStatusCode`
* `update_ph_terms(sp::<ConcreteSubtype>, w_vals::Dict{VariableID,Float64}, xhat_vals::Dict{VariableID,Float64})::Nothing`
See help strings on each function for details on arguments, returned objects and expected performance of each function. See JuMPSubproblem for an example using JuMP.

To use `warm_start=true` the concrete subtype must also implement
* `warm_start(sp::<ConcreteSubtype>)::Nothing`
See help on `warm_start` for more information.  See JuMPSubproblem for an example using JuMP.

To use the extensive form functionality, the concrete subtype must implement
* `ef_copy_model(destination::JuMP.Model, original::<ConcreteSubtype>, scid::ScenarioID, scen_tree::ScenarioTree, node_dict::Dict{NodeID,Any})
* `ef_node_dict_constructor(::Type{S}) where S <: AbstractSubproblem`
See the help on the functions for more details. See JuMPSubproblem for an example using JuMP. Note that the extensive form model is always constructed as a `JuMP.Model` object.
"""
abstract type AbstractSubproblem end

## Required Interface Functions ##

# The below functions must be implemented by any new subtype of AbstractSubproblem.
# Note they all default to throwing an `UnimplementedError`.

"""
    add_ph_objective_terms(as::AbstractSubproblem,
                           vids::Vector{VariableID},
                           r::AbstractPenaltyParameter
                           )::Dict{VariableID,Float64}

Create model variables for Lagrange multipliers and hat variables and add lagrange and quadratic penalty terms to the objective function.

Returns mapping of the variable to any information needed from the subproblem to compute the penalty parameter. Only used if `is_subproblem_dependent(typeof(r))` returns `true`.

**Arguments**

* `as::AbstractSubproblem` : subproblem object (replace with appropriate type)
* `vids::Vector{VariableID}` : list of `VariableIDs` which need ph terms created
* `r::AbstractPenaltyParameter` : penalty parameter on quadratic term
"""
function add_ph_objective_terms(as::AbstractSubproblem,
                                vids::Vector{VariableID},
                                r::Union{Float64,Dict{VariableID,Float64}},
                                )::Dict{VariableID,Float64}
    throw(UnimplementedError("add_ph_objective_terms is unimplemented"))
end

"""
    objective_value(as::AbstractSubproblem)::Float64

Return the objective value of the solved subproblem.

**Arguments**

* `as::AbstractSubproblem` : subproblem object (replace with appropriate type)
"""
function objective_value(as::AbstractSubproblem)::Float64
    throw(UnimplementedError("objective_value is unimplemented"))
end

"""
TODO: Add documentation for this function!!!!
"""
function report_penalty_info(as::AbstractSubproblem,
                             pp::Type{P},
                             )::Dict{VariableID,Float64} where P <: AbstractPenaltyParameter
    throw(UnimplementedError("report_penalty_info is unimplmented for subproblem of type $(typeof(as)) and penalty parameter of type $(pp)."))
end

"""
    report_variable_info(as::AbstractSubproblem,
                         st::ScenarioTree
                         )::Dict{VariableID, String}

Assign `VariableID`s to all model variables and build a map from those ids to the variable name.

**Arguments**

* `as::AbstractSubproblem` : subproblem object (replace with appropriate type)
* `st::ScenarioTree` : scenario tree for the entire PH problem
"""
function report_variable_info(as::AbstractSubproblem,
                              st::ScenarioTree
                              )::Dict{VariableID, String}
    throw(UnimplementedError("report_variable_info is unimplemented"))
end

"""
    report_values(as::AbstractSubproblem,
                  vars::Vector{VariableID}
                  )::Dict{VariableID, Float64}

Return the variable values specified by `vars`.

**Arguments**

* `as::AbstractSubproblem` : subproblem object (replace with appropriate type)
* `vars::Vector{VariableID}` : collection of `VariableID`s to gather values for
"""
function report_values(as::AbstractSubproblem,
                       vars::Vector{VariableID}
                       )::Dict{VariableID, Float64}
    throw(UnimplementedError("report_values is unimplemented"))
end

"""
    solve(as::AbstractSubproblem)::MOI.TerminationStatusCode

Solve the subproblem specified by `as` and return the status code.

**Arguments**

* `as::AbstractSubproblem` : subproblem object (replace with appropriate type)
"""
function solve(as::AbstractSubproblem)::MOI.TerminationStatusCode
    throw(UnimplementedError("solve is unimplemented"))
end

"""
    update_ph_terms(as::AbstractSubproblem,
                    w_vals::Dict{VariableID,Float64},
                    xhat_vals::Dict{VariableID,Float64}
                    )::Nothing

Update the values of the PH variables in this subproblem with those given by `w_vals` and `xhat_vals`.

**Arguments**

* `as::AbstractSubproblem` : subproblem object (replace with appropriate type)
"""
function update_ph_terms(as::AbstractSubproblem,
                         w_vals::Dict{VariableID,Float64},
                         xhat_vals::Dict{VariableID,Float64}
                         )::Nothing
    throw(UnimplementedError("update_ph_terms is unimplemented"))
end

"""
    warm_start(as::AbstractSubproblem)::Nothing

Use the values of previous solves non-PH variables as starting points of the next solve.

**Arguments**

* `as::AbstractSubproblem` : subproblem object (replace with appropriate type)
"""
function warm_start(as::AbstractSubproblem)::Nothing
    throw(UnimplementedError("warm_start is unimplemented"))
end

## Optional Interface Functions ##

# These functions are required only if an extensive form construction is desired

"""
    ef_copy_model(destination::JuMP.Model,
                  original::AbstractSubproblem,
                  scid::ScenarioID,
                  scen_tree::ScenarioTree,
                  node_dict::Dict{NodeID, Any}
                  )

Copy the subproblem described by `original` to the extensive form model `destination`.

**Arguments**

* `destination::JuMP.Model` : extensive form of the model that is being built
* `original::AbstractSubproblem` : subproblem object (replace with appropriate type)
* `scid::ScenarioID` : `ScenarioID` corresponding to this subproblem
* `scen_tree::ScenarioTree` : scenario tree for the entire PH problem
* `node_dict::Dict{NodeID, Any}` : dictionary for transferring nodal information from one submodel to another
"""
function ef_copy_model(destination::JuMP.Model,
                       original::AbstractSubproblem,
                       scid::ScenarioID,
                       scen_tree::ScenarioTree,
                       node_dict::Dict{NodeID, Any}
                       )
    throw(UnimplementedError("ef_copy_model is unimplemented"))
end

"""
    ef_node_dict_constructor(::Type{S}) where S <: AbstractSubproblem

Construct dictionary that is used to carry information between subproblems for `ef_copy_model`.

**Arguments**

* `::Type{S}` : Subproblem type
"""
function ef_node_dict_constructor(::Type{S}) where S <: AbstractSubproblem
    throw(UnimplementedError("ef_node_dict_constructor is unimplemented"))
end
