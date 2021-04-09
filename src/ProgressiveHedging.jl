module ProgressiveHedging

import DataFrames
import JuMP
import MathOptInterface
const MOI = MathOptInterface

using Distributed
using Printf
using TimerOutputs

#### Exports ####

# High-level Functions
export solve, solve_extensive

# Callbacks
export Callback
export variable_reduction

# ID types and functions
export Index, NodeID, ScenarioID, StageID, VariableID, XhatID
export index, scenario, stage, value

# Penalty Parameter types and functions
export AbstractPenaltyParameter
export ProportionalPenaltyParameter, ScalarPenaltyParameter, SEPPenaltyParameter

# PHData interaction function
export convert_to_variable_ids, convert_to_xhat_id
export is_leaf, name, ph_variables, probability

# Result retrieval functions
export residuals, retrieve_soln, retrieve_obj_value, retrieve_no_hats, retrieve_w

# Scenario tree types and functions
export ScenarioTree
export add_node, add_leaf, root, two_stage_tree

# Subproblems types and functions
export AbstractSubproblem, JuMPSubproblem

#### Includes ####

include("id_types.jl")
include("penalty_parameter.jl")
include("scenario_tree.jl")

include("subproblem.jl")
include("jumpsubproblem.jl")

include("message.jl")
include("worker.jl")
include("worker_management.jl")

include("structs.jl")

include("utils.jl")

include("algorithm.jl")
include("setup.jl")

include("callbacks.jl")

#### Functions ####

"""
    solve(tree::ScenarioTree,
          subproblem_constructor::Function,
          r<:Real,
          other_args...;
          max_iter::Int=1000,
          atol::Float64=1e-6,
          rtol::Float64=1e-6,
          report::Int=0,
          save_iterates::Int=0,
          save_residuals::Bool=false,
          timing::Bool=true,
          callbacks::Vector{Callback}=Vector{Callback}(),
          args::Tuple=(),
          kwargs...)

Solve the stochastic programming problem described by `tree` and the models created by `subproblem_constructor` using Progressive Hedging.

**Arguments**

* `tree::ScenararioTree` : Scenario tree describing the structure of the problem to be solved.
* `subproblem_constructor::Function` : User created function to construct a subproblem. Should accept a `ScenarioID` (a unique identifier for each scenario subproblem) as an argument and returns a subtype of `AbstractSubproblem`.
* `r<:AbstractPenaltyParameter` : PH penalty parameter
* `other_args` : Other arguments that should be passed to `subproblem_constructor`. See also keyword arguments `args` and `kwargs`.

**Keyword Arguments**

* `max_iter::Int` : Maximum number of iterations to perform before returning. Defaults to 1000.
* `atol::Float64` : Absolute error tolerance. Defaults to 1e-6.
* `rtol::Float64` : Relative error tolerance. Defaults to 1e-6.
* `report::Int` : Print progress to screen every `report` iterations. Any value <= 0 disables printing. Defaults to 0.
* `save_iterates::Int` : Save PH iterates every `save_iterates` steps. Any value <= 0 disables saving iterates. Defaults to 0.
* `save_residuals::Int` : Save PH residuals every `save_residuals` steps. Any value <= 0 disables saving residuals. Defaults to 0.
* `timing::Bool` : Flag indicating whether or not to record timing information. Defaults to true.
* `warm_start::Bool` : Flag indicating that solver should be "warm started" by using the previous solution as the starting point (not compatible with all solvers)
* `callbacks::Vector{Callback}` : Collection of `Callback` structs to call after each PH iteration. See `Callback` struct for more info. Defaults to empty vector.
* `args::Tuple` : Tuple of arguments to pass to `model_cosntructor`. Defaults to (). See also `other_args` and `kwargs`.
* `kwargs` : Any keyword arguments not specified here that need to be passed to `subproblem_constructor`.  See also `other_args` and `args`.
"""
function solve(tree::ScenarioTree,
               subproblem_constructor::Function,
               r::R,
               other_args...;
               max_iter::Int=1000,
               atol::Float64=1e-6,
               rtol::Float64=1e-6,
               report::Int=0,
               save_iterates::Int=0,
               save_residuals::Int=0,
               timing::Bool=true,
               warm_start::Bool=false,
               callbacks=Vector{Callback}(),
               args::Tuple=(),
               kwargs...
               ) where {R <: AbstractPenaltyParameter}
               
    timo = TimerOutputs.TimerOutput()

    if length(scenarios(tree)) == 1
        @warn("Given scenario tree indicates a deterministic problem (only one scenario).")
    elseif length(scenarios(tree)) <= 0
        error("Given scenario tree has no scenarios specified. Make sure 'add_leaf' is being called on leaves of the scenario tree.")
    end

    psum = sum(values(tree.prob_map))
    if !isapprox(psum, 1.0, atol=1e-8)
        error("Total probability of scenarios in given scenario tree is $psum.")
    end

    # Initialization
    if report > 0
        println("Initializing...")
    end

    (phd, winf) = @timeit(timo,
                          "Intialization",
                          initialize(tree,
                                     subproblem_constructor,
                                     r,
                                     warm_start,
                                     timo,
                                     report,
                                     (other_args...,args...);
                                     kwargs...)
                          )

    for cb in callbacks
        _add_callback(phd, cb)
        cb.initialize(cb.ext, phd)
    end

    # Solution
    if report > 0
        println("Solving...")
    end
    (niter, abs_res, rel_res) = @timeit(timo, "Solution",
                                        hedge(phd,
                                              winf,
                                              max_iter,
                                              atol,
                                              rtol,
                                              report,
                                              save_iterates,
                                              save_residuals)
                                        )

    # Post Processing
    if report > 0
        println("Done.")
    end

    soln_df = retrieve_soln(phd)
    obj = retrieve_obj_value(phd)

    if timing
        println(timo)
    end

    return (niter, abs_res, rel_res, obj, soln_df, phd)
end

"""
    solve_extensive(tree::ScenarioTree,
          subproblem_constructor::Function,
          optimizer::Function,
          other_args...;
          opt_args::NamedTuple=NamedTuple(),
          subproblem_type::Type{S}=JuMPSubproblem,
          args::Tuple=(),
          kwargs...)

Solve given problem using Progressive Hedging.

**Arguments**

* `tree::ScenararioTree` : Scenario tree describing the structure of the problem to be solved.
* `subproblem_constructor::Function` : User created function to construct a subproblem. Should accept a `ScenarioID` (a unique identifier for each scenario subproblem) as an argument and returns a subtype of `AbstractSubproblem` specified by `subproblem_type`.
* `optimizer::Function` : Function which works with `JuMP.set_optimizer`
* `other_args` : Other arguments that should be passed to `subproblem_constructor`. See also keyword arguments `args` and `kwargs`

**Keyword Arguments**

* `subproblem_type<:JuMP.AbstractModel` : Type of model to create or created by `subproblem_constructor` to represent the subproblems. Defaults to JuMPSubproblem
* `opt_args::NamedTuple` : arguments passed to function given by `optimizer`
* `args::Tuple` : Tuple of arguments to pass to `model_cosntructor`. Defaults to (). See also `other_args` and `kwargs`.
* `kwargs` : Any keyword arguments not specified here that need to be passed to `subproblem_constructor`.  See also `other_args` and `args`.
"""
function solve_extensive(tree::ScenarioTree,
                         subproblem_constructor::Function,
                         optimizer::Function,
                         other_args...;
                         opt_args::NamedTuple=NamedTuple(),
                         subproblem_type::Type{S}=JuMPSubproblem,
                         args::Tuple=(),
                         kwargs...
                         ) where {S <: AbstractSubproblem}

    if length(scenarios(tree)) == 1
        @warn("Given scenario tree indicates a deterministic problem (only one scenario).")
    elseif length(scenarios(tree)) <= 0
        error("Given scenario tree has no scenarios specified. Make sure 'add_leaf' is being called on leaves of the scenario tree.")
    end

    psum = sum(values(tree.prob_map))
    if psum > 1.0 || psum < 1.0
        error("Total probability of scenarios in given scenario tree is $psum.")
    end

    model = build_extensive_form(tree,
                                 subproblem_constructor,
                                 Tuple([other_args...,args...]),
                                 subproblem_type;
                                 kwargs...)

    JuMP.set_optimizer(model, optimizer)
    for (key, value) in pairs(opt_args)
        JuMP.set_optimizer_attribute(model, string(key), value)
    end
    JuMP.optimize!(model)

    return model
end


end # module

#### TODOs ####

# 1. Add tests for unimplemented subproblem error throwing?
# 2. Add flag to solve call to turn off parallelism
# 3. Add handling of nonlinear objective functions
# 4. Add tests for nonlinear constraints (these should work currently but testing is needed)
