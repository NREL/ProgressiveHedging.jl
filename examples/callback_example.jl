
using Pkg
Pkg.activate(@__DIR__)

using ProgressiveHedging
import JuMP
import Ipopt

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

scen_tree = two_stage_tree(2)

function my_callback(ext::Dict{Symbol,Any},
                     phd::PHData,
                     winf::ProgressiveHedging.WorkerInf,
                     niter::Int)
    # The `ext` dictionary can be used to store things between PH iterations
    if niter == 2
        ext[:message] = "This is from iteration 2!"
    elseif niter == 5
        println("Iteration 5 found the message: " * ext[:message])
    elseif niter == 10
        println("This is iteration 10!")
        # We can access the current consensus variable values
        for (xhid, xhat) in pairs(consensus_variables(phd))
            println("The value of $(name(phd,xhid)) is $(value(xhat)).")
        end
    end
    # Returning false from the callback will terminate PH.
    # Here we stop after 20 iterations.
    return niter < 20
end

my_cb = Callback(my_callback)

(niter, abs_res, rel_res, obj, soln_df, phd) = solve(scen_tree,
                                                     two_stage_model,
                                                     ScalarPenaltyParameter(1.0),
                                                     callbacks=[my_cb]
                                                     )
@show niter
@show abs_res
@show rel_res
@show obj
@show soln_df
