
using Distributed
addprocs(2) # add 2 workers

@everywhere using Pkg
@everywhere Pkg.activate(joinpath(@__DIR__, "..", "examples"))

@everywhere using ProgressiveHedging
@everywhere import JuMP
@everywhere import Ipopt

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
