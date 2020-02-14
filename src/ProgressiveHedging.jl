module ProgressiveHedging

import JuMP
import StructJuMP
import DataFrames

using TimerOutputs

import MathOptInterface
const MOI = MathOptInterface

using Distributed

#export solve

# TODO: Find a way to return the objective value for each scenario

# TODO: Pass in actual error function for adding things in case something
# goes wrong. Currently just a function stub.

include("structs.jl")
include("utils.jl")

include("algorithm.jl")
include("setup.jl")
"""
    solve(root_model::StructJuMP.StructuredModel,
          optimizer_factory::JuMP.OptimizerFactory,
          r<:Real;
          model_type<:JuMP.AbstractModel=JuMP.Model,
          max_iter::Int=100,
          atol::Float64=1e-8,
          report::Bool=false,
          timing::Bool=true)

    solve(tree::ScenarioTree,
          model_constructor::Function,
          variable_dict::Dict{Int,Vector{String}},
          optimizer_factory::JuMP.OptimizerFactory,
          r<:Real,
          other_args...;
          model_type<:JuMP.AbstractModel=JuMP.Model,
          max_iter::Int=100,
          atol::Float64=1e-8,
          report::Bool=false,
          timing::Bool=true,
          args::Tuple=(),
          kwargs...)

Solve given problem using Progressive Hedging.

**Arguments**

* `root_model::StructJuMP.StructuredModel` : First stage model of the StructJuMP tree that describes the problem to be solved.
* `tree::ScenararioTree` : Scenario tree describing the structure of the problem to be solved.
* `model_constructor::Function` : User created function to construct a subproblem model.  Should accept an Int (a unique identifier for the scenario) and a `JuMP.OptimizerFactory` and return a model of type `model_type`.  Additional arguments may be passed with `other_args` or through `kwargs` (provided they don't collide with the keyword arguments for `solve`.
* `variable_dict::Dict{Int,Vector{String}}` : Dictionary specifying the names of variables (value) in a given stage (key).
* `optimizer_factory::JuMP.OptimizerFactory` : Optimizer to use to solve subproblems. See JuMP.OptimizerFactory and JuMP.with_optimizer for more details.
* `r<:Real` : Parameter to use on quadratic penalty term.
* `other_args` : Other arguments that should be passed to `model_constructor`. See also keyword arguments `args` and `kwargs`

**Keyword Arguments**

* `model_type<:JuMP.AbstractModel` : Type of model to create or created by `model_constructor` to represent the subproblems. Defaults to JuMP.Model.
* `max_iter::Int` : Maximum number of iterations to perform before returning. Defaults to 100.
* `atol::Float64` : Absolute error tolerance. If total disagreement amongst variables is less than this in the L^2 sense, then return. Defaults to 1e-8
* `report::Bool` : Flag indicating whether or not to report information while running. Defaults to false.
* `timing::Bool` : Flag indicating whether or not to record timing information. Defaults to true.
* `args::Tuple` : Tuple of arguments to pass to `model_cosntructor`. Defaults to (). See also `other_args` and `kwargs`.
* `kwargs` : Any keyword arguments not specified here that need to be passed to `model_constructor`.  See also `other_args` and `args`.

"""
function solve(root_model::StructJuMP.StructuredModel,
               optimizer_factory::JuMP.OptimizerFactory,
               r::T;
               model_type::Type{M}=JuMP.Model,
               max_iter::Int=100, atol::Float64=1e-8,
               report::Bool=false, timing::Bool=true
               ) where {T <: Real, M <: JuMP.AbstractModel}
    # Initialization
    timo = TimerOutputs.TimerOutput()

    if report
        println("Initializing...")
    end

    ph_data = @timeit(timo, "Initialization",
                      initialize(root_model, r,
                                 optimizer_factory,
                                 M,
                                 timo, report)
                      )

    # Solution
    if report
        println("Solving...")
    end
    (niter, residual) = @timeit(timo, "Solution",
                                hedge(ph_data, max_iter, atol, report)
                                )

    # Post Processing
    if report
        println("Done.")
    end

    soln_df = retrieve_soln(ph_data)
    obj = retrieve_obj_value(ph_data)

    if timing
        println(timo)
    end

    return (niter, residual, obj, soln_df, ph_data)
end

function solve(tree::ScenarioTree,
               model_constructor::Function,
               variable_dict::Dict{STAGE_ID,Vector{String}},
               optimizer_factory::JuMP.OptimizerFactory,
               r::T,
               other_args...;
               model_type::Type{M}=JuMP.Model,
               max_iter::Int=100,
               atol::Float64=1e-8,
               report::Bool=false, timing::Bool=true,
               args::Tuple=(), kwargs...
               ) where {T <: Real, M <: JuMP.AbstractModel}
    timo = TimerOutputs.TimerOutput()

    # Initialization
    if report
        println("Initializing...")
    end

    ph_data = @timeit(timo, "Intialization",
                      initialize(tree,
                                 model_constructor,
                                 variable_dict,
                                 r,
                                 optimizer_factory,
                                 M,
                                 timo,
                                 report,
                                 Tuple([other_args...,args...]);
                                 kwargs...))

    # Solution
    if report
        println("Solving...")
    end
    (niter, residual) = @timeit(timo, "Solution",
                                hedge(ph_data, max_iter, atol, report))

    # Post Processing
    if report
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

function solve_extensive_form(root_model::StructJuMP.StructuredModel,
                              optimizer_factory::JuMP.OptimizerFactory;
                              model_type::Type{M}=JuMP.Model, kwargs...
                              ) where {M <: JuMP.AbstractModel}
    model = @spawnat(1, M(kwargs...)) # Always local
    build_extensive_form(root_model, model)
    JuMP.optimize!(fetch(model), optimizer_factory)
    return fetch(model)
end

end # module
