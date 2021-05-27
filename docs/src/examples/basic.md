# Basic Example

A basic example on using ProgressiveHedging.jl.

This example is also available as the script basic_example.jl in the example directory.

Here we will use ProgressiveHedging.jl to solve the simple problem

``\min_x x + \sum_{s=0}^1 p_s c_s y_s``

subject to

``x \ge 0``

``y_s \ge 0, s \in {0,1}``

``x + y = b_s``

where

``
b_s = \begin{cases} 11, & s=0 \\ 4, & s=1 \end{cases},
``

``
c_s = \begin{cases} 0.5, & s=0 \\ 10, & s=1 \end{cases}
``

and for now we will take equally probable scenarios, that is, ``p_0 = p_1 = 0.5``.

First we need to bring in the needed packages

```@example basic
using ProgressiveHedging
import JuMP
import Ipopt
```

We will need JuMP to build the model for each subproblem and we will use Ipopt to solve it.

**Note:** There are some functions that both JuMP and ProgressiveHedging export. To avoid confusion (and warnings) it is best to import one or both of these packages.

Next, we write a function that will generate the subproblems for each scenario. The following creates the subproblem for a simple two stage stochastic program.

```@example basic
function two_stage_model(scenario_id::ScenarioID)

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
nothing # hide
```

There are a few things to note here:
* This function must take as an argument a [`ScenarioID`](@ref).
* The mathematical model is built using JuMP.
* The function returns a [`JuMPSubproblem`](@ref). This is an implementation of the [`AbstractSubproblem`](@ref) interface which uses JuMP as the algebraic modeling language.
* In addition to the model, the subproblem also requires the [`ScenarioID`](@ref) and a dictionary identifying which variables belong in which stage.

Second we need to construct a [`ScenarioTree`](@ref) that captures the structure of our stochastic program. We can do this using the [`ScenarioTree`](@ref) constructor and the function [`add_leaf`](@ref):

```@example basic
scen_tree = ScenarioTree()
add_leaf(scen_tree, root(scen_tree), 0.5)
add_leaf(scen_tree, root(scen_tree), 0.5)
nothing # hide
```

Here we created a scenario tree and added two leaf nodes each representing the two scenarios in our problem. We specified both occur with probability 0.5.

Since two-stage stochastic programs are extremely common, ProgressiveHedging.jl provides a convenience function to generate two-stage trees with arbitrarily many scenarios: [`two_stage_tree`](@ref).

We are now ready to solve the problem. To do so we just use the [`solve`](@ref) function.

```@example basic
(niter, abs_res, rel_res, obj, soln_df, phd) = solve(scen_tree,
                                                     two_stage_model,
                                                     ScalarPenaltyParameter(1.0)
                                                     )
@show niter
@show abs_res
@show rel_res
@show obj
@show soln_df
nothing # hide
```

The solve function returns the number of iteration, the absolute and relative residual, the objective value, a `DataFrame` containing the solution and, lastly, a [`PHData`](@ref) instance.

The [`PHData`](@ref) contains additional information like the dual (Lagrange multiplier) values for the nonanticipativity constraints

```@example basic
dual_df = retrieve_w(phd)
@show dual_df
nothing # hide
```

as well as the raw values of the consensus contributing variables

```@example basic
raw_values_df = retrieve_no_hats(phd)
@show raw_values_df
nothing # hide
```

For smaller problems, it is also possible to solve the extensive form of the problem directly. ProgressiveHedging.jl is capable of building the extensive form from the previously defined function and scenario tree.

```@example basic
ef_model = solve_extensive(scen_tree,
                           two_stage_model,
                           ()->Ipopt.Optimizer(),
                           opt_args=(print_level=0, tol=1e-12, acceptable_tol=1e-12)
                           )

nothing # hide
```

This function builds, optimizes and returns a JuMP model of the extensive form. As such, information is obtained from it as from any other JuMP model.

```@example basic
@show JuMP.termination_status(ef_model)
@show JuMP.objective_value(ef_model)
for v in JuMP.all_variables(ef_model)
    println("$v = $(JuMP.value(v))")
end
nothing # hide
```

**NOTE:** The subscripts in the variable names are the scenarios to which the variable belongs.
