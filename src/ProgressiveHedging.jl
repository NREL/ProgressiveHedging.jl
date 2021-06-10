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
export cb, mean_deviation, variable_fixing
export apply_to_subproblem
export SubproblemCallback, spcb

# Exceptions
export UnimplementedError

# ID types and functions
export Index, NodeID, ScenarioID, StageID, VariableID, XhatID
export index, scenario, stage, value
export scid, stid, index
export convert_to_variable_ids, convert_to_xhat_id, stage_id

# Penalty Parameter Interface
export AbstractPenaltyParameter
export get_penalty_value
export is_initial_value_dependent, is_subproblem_dependent, is_variable_dependent
export penalty_map
export process_penalty_initial_value
export process_penalty_subproblem

# Penalty Parameter (Concrete)
export ProportionalPenaltyParameter, ScalarPenaltyParameter, SEPPenaltyParameter

# PHData interaction function
export PHData
export consensus_variables, probability, scenario_tree, scenarios
export get_callback, get_callback_ext

# Result retrieval functions
export lower_bounds
export print_timing
export residuals
export retrieve_aug_obj_value, retrieve_obj_value
export retrieve_soln, retrieve_no_hats, retrieve_w
export retrieve_xhat_history, retrieve_no_hat_history, retrieve_w_history

# Scenario tree types and functions
export ScenarioNode, ScenarioTree
export add_node, add_leaf, root, two_stage_tree

# Subproblem Interface
export AbstractSubproblem, VariableInfo
export add_ph_objective_terms, objective_value, report_values, report_variable_info
export solve_subproblem, update_ph_terms
export warm_start
export ef_copy_model
export ef_node_dict_constructor
export report_penalty_info
export add_lagrange_terms, update_lagrange_terms

# Subproblems Types (Concrete)
export JuMPSubproblem

# (Consensus) Variable interaction functions
export HatVariable
export is_leaf, name, value, branch_value, leaf_value, w_value, xhat_value
export is_integer, scenario_bundle, value, variables

#### Includes ####

include("id_types.jl")
include("penalty_parameter_types.jl")
include("scenario_tree.jl")

include("subproblem.jl")
include("jumpsubproblem.jl")

include("subproblem_callback.jl")
include("message.jl")
include("worker.jl")
include("worker_management.jl")

include("structs.jl")
include("penalty_parameter_functions.jl")

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
          gap_tol::Float64=-1.0,
          lower_bound::Int=0,
          report::Int=0,
          save_iterates::Int=0,
          save_residuals::Bool=false,
          timing::Bool=true,
          warm_start::Bool=false,
          callbacks::Vector{Callback}=Vector{Callback}(),
          worker_assignments::Dict{Int,Set{ScenarioID}}=Dict{Int,Set{ScenarioID}}(),
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
* `gap_tol::Float64` : Relative gap tolerance. Terminate when the relative gap between the lower bound and objective are smaller than `gap_tol`. Any value < 0.0 disables this termination condition. Defaults to -1.0. See also the `lower_bound` keyword argument.
* `lower_bound::Int` : Compute and save a lower-bound using (Gade, et. al. 2016) every `lower_bound` iterations. Any value <= 0 disables lower-bound computation. Defaults to 0.
* `report::Int` : Print progress to screen every `report` iterations. Any value <= 0 disables printing. Defaults to 0.
* `save_iterates::Int` : Save PH iterates every `save_iterates` steps. Any value <= 0 disables saving iterates. Defaults to 0.
* `save_residuals::Int` : Save PH residuals every `save_residuals` steps. Any value <= 0 disables saving residuals. Defaults to 0.
* `timing::Bool` : Print timing info after solving if true. Defaults to true.
* `warm_start::Bool` : Flag indicating that solver should be "warm started" by using the previous solution as the starting point (not compatible with all solvers)
* `callbacks::Vector{Callback}` : Collection of `Callback` structs to call after each PH iteration. Callbacks will be executed in the order they appear. See `Callback` struct for more info. Defaults to empty vector.
* `subproblem_callbacks::Vector{SubproblemCallback}` : Collection of `SubproblemCallback` structs to call before solving each subproblem. Each callback is called on each subproblem but does not affect other subproblems. See `SubproblemCallback` struct for more info. Defaults to empty vector.
* `worker_assignments::Dict{Int,Set{ScenarioID}}` : Dictionary specifying which scenario subproblems a worker will create and solve. The key values are worker ids as given by Distributed (see `Distributed.workers()`). The user is responsible for ensuring the specified workers exist and that every scenario is assigned to a worker. If no dictionary is given, scenarios are assigned to workers in round robin fashion. Defaults to empty dictionary.
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
               gap_tol::Float64=-1.0,
               lower_bound::Int=0,
               report::Int=0,
               save_iterates::Int=0,
               save_residuals::Int=0,
               timing::Bool=false,
               warm_start::Bool=false,
               callbacks::Vector{Callback}=Vector{Callback}(),
               subproblem_callbacks::Vector{SubproblemCallback}=Vector{SubproblemCallback}(),
               worker_assignments::Dict{Int,Set{ScenarioID}}=Dict{Int,Set{ScenarioID}}(),
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
                                     worker_assignments,
                                     warm_start,
                                     timo,
                                     report,
                                     lower_bound,
                                     subproblem_callbacks,
                                     (other_args...,args...);
                                     kwargs...)
                          )

    for cb in callbacks
        add_callback(phd, cb)
    end

    # Solution
    if report > 0
        println("Solving...")
    end
    (niter, abs_res, rel_res) = @timeit(timo,
                                        "Solution",
                                        hedge(phd,
                                              winf,
                                              max_iter,
                                              atol,
                                              rtol,
                                              gap_tol,
                                              report,
                                              save_iterates,
                                              save_residuals,
                                              lower_bound)
                                        )

    # Post Processing
    if report > 0
        println("Done.")
    end

    soln_df = retrieve_soln(phd)
    obj = retrieve_obj_value(phd)

    if timing
        print_timing(phd)
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
    if !isapprox(psum, 1.0, atol=1e-8)
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

# 1. Add flag to solve call to turn off parallelism
# 2. Add handling of nonlinear objective functions
# 3. Add tests for nonlinear constraints (these should work currently but testing is needed)
