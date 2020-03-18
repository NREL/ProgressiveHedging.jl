module ProgressiveHedging

import JuMP
# import StructJuMP
import DataFrames

using TimerOutputs

import MathOptInterface
const MOI = MathOptInterface

using Distributed

# Functions for solving the problem
export solve, solve_extensive
# Functions for building the scenario tree
export add_node, add_leaf, root
# Functions for interacting with the returned PHData struct
export residuals, retrieve_soln, retrieve_obj_value, retrieve_no_hats, retrieve_w

# TODO: Find a way to return the objective value for each scenario

# TODO: Pass in actual error function for adding things in case something
# goes wrong. Currently just a function stub.

include("structs.jl")
include("utils.jl")

include("algorithm.jl")
include("setup.jl")

"""
    solve(tree::ScenarioTree,
          model_constructor::Function,
          variable_dict::Dict{Int,Vector{String}},
          r<:Real,
          other_args...;
          model_type<:JuMP.AbstractModel=JuMP.Model,
          max_iter::Int=1000,
          atol::Float64=1e-8,
          report::Int=0,
          save_residuals::Bool=false,
          timing::Bool=true,
          args::Tuple=(),
          kwargs...)

Solve given problem using Progressive Hedging.

**Arguments**

* `tree::ScenararioTree` : Scenario tree describing the structure of the problem to be solved.
* `model_constructor::Function` : User created function to construct a subproblem model.  Should accept an Int (a unique identifier for the scenario) and return a model of type `model_type`.  Additional arguments may be passed with `other_args` or through `kwargs` (provided they don't collide with the keyword arguments for `solve`.
* `variable_dict::Dict{Int,Vector{String}}` : Dictionary specifying the names of variables (value) in a given stage (key).
* `r<:Real` : Parameter to use on quadratic penalty term.
* `other_args` : Other arguments that should be passed to `model_constructor`. See also keyword arguments `args` and `kwargs`

**Keyword Arguments**

* `model_type<:JuMP.AbstractModel` : Type of model to create or created by `model_constructor` to represent the subproblems. Defaults to JuMP.Model.
* `max_iter::Int` : Maximum number of iterations to perform before returning. Defaults to 1000.
* `atol::Float64` : Absolute error tolerance. If total disagreement amongst variables is less than this in the L^2 sense, then return. Defaults to 1e-8.
* `report::Int` : Print progress to screen every `report` iterations. Any value <= 0 disables printing. Defaults to 0.
* `save_residuals::Bool` : Flag indicating whether or not to save residuals from all iterations of the algorithm
* `timing::Bool` : Flag indicating whether or not to record timing information. Defaults to true.
* `warm_start::Bool` : Flag indicating that solver should be "warm started" by using the previous solution as the starting point (not compatible with all solvers)
* `args::Tuple` : Tuple of arguments to pass to `model_cosntructor`. Defaults to (). See also `other_args` and `kwargs`.
* `kwargs` : Any keyword arguments not specified here that need to be passed to `model_constructor`.  See also `other_args` and `args`.
"""
function solve(tree::ScenarioTree,
               model_constructor::Function,
               variable_dict::Dict{STAGE_ID,Vector{String}},
               r::T,
               other_args...;
               model_type::Type{M}=JuMP.Model,
               max_iter::Int=1000,
               atol::Float64=1e-8,
               report::Int=0,
               save_residuals::Bool=false,
               timing::Bool=true,
               warm_start::Bool=false,
               args::Tuple=(),
               kwargs...
               ) where {T <: Real, M <: JuMP.AbstractModel}
    timo = TimerOutputs.TimerOutput()

    # Initialization
    if report > 0
        println("Initializing...")
    end

    ph_data = @timeit(timo, "Intialization",
                      initialize(tree,
                                 model_constructor,
                                 variable_dict,
                                 r,
                                 M,
                                 timo,
                                 report,
                                 Tuple([other_args...,args...]);
                                 kwargs...))

    # Solution
    if report > 0
        println("Solving...")
    end
    (niter, residual) = @timeit(timo, "Solution",
                                hedge(ph_data, max_iter, atol,
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

    # return (niter, residual, soln_df, cost_dict, ph_data)
    return (niter, residual, obj, soln_df, ph_data)
end

"""
    solve_extensive(tree::ScenarioTree,
          model_constructor::Function,
          variable_dict::Dict{Int,Vector{String}},
          other_args...;
          model_type<:JuMP.AbstractModel=JuMP.Model,
          atol::Float64=1e-8,
          args::Tuple=(),
          kwargs...)

Solve given problem using Progressive Hedging.

**Arguments**

* `tree::ScenararioTree` : Scenario tree describing the structure of the problem to be solved.
* `model_constructor::Function` : User created function to construct a subproblem model.  Should accept an Int (a unique identifier for the scenario) and return a model of type `model_type`.  Additional arguments may be passed with `other_args` or through `kwargs` (provided they don't collide with the keyword arguments for `solve`.
* `variable_dict::Dict{Int,Vector{String}}` : Dictionary specifying the names of variables (value) in a given stage (key).
* `other_args` : Other arguments that should be passed to `model_constructor`. See also keyword arguments `args` and `kwargs`

**Keyword Arguments**

* `model_type<:JuMP.AbstractModel` : Type of model to create or created by `model_constructor` to represent the subproblems. Defaults to JuMP.Model.
* `optimizer::Function` : Function which works with `JuMP.set_optimizer`
* `args::Tuple` : Tuple of arguments to pass to `model_cosntructor`. Defaults to (). See also `other_args` and `kwargs`.
* `kwargs` : Any keyword arguments not specified here that need to be passed to `model_constructor`.  See also `other_args` and `args`.
"""
function solve_extensive(tree::ScenarioTree,
                         model_constructor::Function,
                         variable_dict::Dict{STAGE_ID,Vector{String}},
                         other_args...;
                         model_type::Type{M}=JuMP.Model,
                         optimizer::Function=()->Ipopt.Optimizer(print_level=0),
                         args::Tuple=(),
                         kwargs...
                         ) where {T <: Real, M <: JuMP.AbstractModel}

    model = build_extensive_form(optimizer, tree, variable_dict,
                                 model_constructor,
                                 Tuple([other_args...,args...]);
                                 kwargs...)

    JuMP.optimize!(model)

    return model
end


end # module
