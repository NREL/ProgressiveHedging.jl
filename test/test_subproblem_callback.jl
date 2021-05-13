@testset "SubproblemCallback" begin
    spcb_text = "SubproblemCallback succesful."
    function my_subproblem_callback(
        ext::Dict{Symbol,Any}, sp::JuMPSubproblem, niter::Int, 
        scenario_id::ScenarioID
    )
        if niter == 1
            println(spcb_text)
        end
    end

    out = @capture_out begin PH.solve(build_scen_tree(),
                                        create_model,
                                        PH.ScalarPenaltyParameter(25.0),
                                        opt=Ipopt.Optimizer,
                                        opt_args=(print_level=1,tol=1e-12),
                                        atol=1e-6,
                                        rtol=1e-8,
                                        max_iter=500,
                                        report=0,
                                        timing=false,
                                        warm_start=false,
                                        subproblem_callbacks=[SubproblemCallback(my_subproblem_callback)])
    end
    
end