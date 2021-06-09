# Distributed Example

An example of how to enable distributed computation within ProgressiveHedging.jl. This example is also available as the script distributed_example.jl in the example directory.

Our first step here is to setup the worker processes. To do this we will use the Julia native [Distributed](https://docs.julialang.org/en/v1/stdlib/Distributed/) package.

```julia
using Distributed
addprocs(2) # add 2 workers
```

Now we need to setup the environment as before but the worker processes need to load the packages too. However, the worker processes are in the default julia environment when launched. If the necessary packages are not installed in this environment, or you want to use a different environment, you'll nee to explicitly activate it for the workers. Here we will activate the examples environment. Activating the proper environment on each worker can be done first by loading `Pkg` on every worker using the `@everywhere` macro and then using `Pkg.activate` to actually activate the environment.

```julia
@everywhere using Pkg
@everywhere Pkg.activate(joinpath(@__DIR__, "..", "examples"))
```

Finally, we again use the Distributed package's `@everywhere` macro to load the needed packages.

```julia
@everywhere using ProgressiveHedging
@everywhere import JuMP
@everywhere import Ipopt
```

Just as in every other case we define the function that is used to create a subproblem. In this case, however, we need to make sure that the worker processes are aware of the function. We once more do this with the `@everywhere` macro.

```julia
@everywhere function two_stage_model(scenario_id::ScenarioID)

    model = JuMP.Model(()->Ipopt.Optimizer())
    JuMP.set_optimizer_attribute(model, "print_level", 0)
    JuMP.set_optimizer_attribute(model, "tol", 1e-12)
    JuMP.set_optimizer_attribute(model, "acceptable_tol", 1e-12)

    scen = value(scenario_id)

    ref = JuMP.@variable(model, x >= 0.0)
    stage1 = [ref]

    ref = JuMP.@variable(model, y >= 0.0)
    stage2 = [ref]

    b_s = scen == 0 ? 11.0 : 4.0
	c_s = scen == 0 ? 0.5 : 10.0

    JuMP.@constraint(model, x + y == b_s)

    JuMP.@objective(model, Min, 1.0*x + c_s*y)

    return JuMPSubproblem(model,
                          scenario_id,
                          Dict(stid(1) => stage1,
                               stid(2) => stage2)
                          )
end
```

Now we proceed just as before. Create the scenario tree and call the solve function. This is all done locally. The rest of the computation distribution will be handled by PH.
```julia
scen_tree = two_stage_tree(2)

(niter, abs_res, rel_res, obj, soln_df, phd) = solve(scen_tree,
                                                     two_stage_model,
                                                     ScalarPenaltyParameter(1.0)
                                                     )
@show niter
@show abs_res
@show rel_res
@show obj
@show soln_df
```

