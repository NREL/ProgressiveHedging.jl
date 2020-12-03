module ProgressiveHedging

import DataFrames
import JuMP
import MathOptInterface
const MOI = MathOptInterface

using Distributed
using Printf
using TimerOutputs

#### Exports ####

## Types

export AbstractSubproblem, JuMPSubproblem

## Functions

# Functions for solving the problem
export solve, solve_extensive
# Functions for building the scenario tree
export add_node, add_leaf, root, two_stage_tree
# Functions for interacting with the returned PHData struct
export residuals, retrieve_soln, retrieve_obj_value, retrieve_no_hats, retrieve_w

#### Includes ####

include("id_types.jl")
include("scenario_tree.jl")
include("subproblem.jl")
include("structs.jl")
include("utils.jl")

include("algorithm.jl")
include("setup.jl")

#### Functions ####

"""
    solve(tree::ScenarioTree,
          subproblem_constructor::Function,
          r<:Real,
          other_args...;
          subproblem_type<:AbstractSubproblem=JuMPSubproblem,
          max_iter::Int=1000,
          atol::Float64=1e-6,
          rtol::Float64=1e-6,
          report::Int=0,
          save_residuals::Bool=false,
          timing::Bool=true,
          args::Tuple=(),
          kwargs...)

Solve given problem using Progressive Hedging.

**Arguments**

* `tree::ScenararioTree` : Scenario tree describing the structure of the problem to be solved.
* `subproblem_constructor::Function` : User created function to construct a subproblem. Should accept a `ScenarioID` (a unique identifier for each scenario subproblem) as an argument and returns a subtype of `AbstractSubproblem` specified by `subproblem_type`.
* `r<:Real` : Parameter to use on quadratic penalty term.
* `other_args` : Other arguments that should be passed to `subproblem_constructor`. See also keyword arguments `args` and `kwargs`

**Keyword Arguments**

* `subproblem_type<:AbstractSubproblem` : Type of model to create or created by `subproblem_constructor` to represent the subproblems. Defaults to JuMPSubproblem.
* `max_iter::Int` : Maximum number of iterations to perform before returning. Defaults to 1000.
* `atol::Float64` : Absolute error tolerance. Defaults to 1e-6.
* `rtol::Float64` : Relative error tolerance. Defaults to 1e-6.
* `report::Int` : Print progress to screen every `report` iterations. Any value <= 0 disables printing. Defaults to 0.
* `save_residuals::Bool` : Flag indicating whether or not to save residuals from all iterations of the algorithm
* `timing::Bool` : Flag indicating whether or not to record timing information. Defaults to true.
* `warm_start::Bool` : Flag indicating that solver should be "warm started" by using the previous solution as the starting point (not compatible with all solvers)
* `args::Tuple` : Tuple of arguments to pass to `model_cosntructor`. Defaults to (). See also `other_args` and `kwargs`.
* `kwargs` : Any keyword arguments not specified here that need to be passed to `subproblem_constructor`.  See also `other_args` and `args`.
"""
function solve(tree::ScenarioTree,
               subproblem_constructor::Function,
               r::T,
               other_args...;
               subproblem_type::Type{S}=JuMPSubproblem,
               max_iter::Int=1000,
               atol::Float64=1e-6,
               rtol::Float64=1e-6,
               report::Int=0,
               save_residuals::Bool=false,
               timing::Bool=true,
               warm_start::Bool=false,
               args::Tuple=(),
               kwargs...
               ) where {T <: Real, S <: AbstractSubproblem}
    timo = TimerOutputs.TimerOutput()

    # Initialization
    if report > 0
        println("Initializing...")
    end

    ph_data = @timeit(timo, "Intialization",
                      initialize(tree,
                                 subproblem_constructor,
                                 r,
                                 subproblem_type,
                                 timo,
                                 report,
                                 Tuple([other_args...,args...]);
                                 kwargs...))

    # Solution
    if report > 0
        println("Solving...")
    end
    (niter, residual) = @timeit(timo, "Solution",
                                hedge(ph_data, max_iter, atol, rtol,
                                      report, save_residuals, warm_start)
                                )

    # Post Processing
    if report > 0
        println("Done.")
    end

    soln_df = retrieve_soln(ph_data)
    obj = retrieve_obj_value(ph_data)

    if timing
        println(timo)
    end

    return (niter, residual, obj, soln_df, ph_data)
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

# 1. Improve error handling of remote exceptions (check for them, figure out a way to
#    retrieve errors that occur when creating subproblems).
# 2. Add tests for unimplemented subproblem error throwing?
# 3. Add flag to solve call to turn off parallelism
# 4. Add handling of nonlinear objective functions
# 5. Add tests for nonlinear constraints (these should work currently but testing is need)
