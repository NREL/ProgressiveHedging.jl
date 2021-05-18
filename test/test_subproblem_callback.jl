@testset "SubproblemCallback" begin
    spcb_text = "SubproblemCallback succesful."
    function my_subproblem_callback(
            ext::Dict{Symbol,Any}, sp::JuMPSubproblem, niter::Int, 
            scenario_id::ScenarioID
        )
        if niter == 1 && scenario_id.value == 0
            ext[:check] += 1
            sp.model.ext[:check] = 1
        end
        if niter == 2 && scenario_id.value == 0
            ext[:sp_check] = sp.model.ext[:check]
        end
    end

    ext = Dict{Symbol,Any}(:check => 0)
    my_spcb = SubproblemCallback(my_subproblem_callback, ext)
    n, err, rerr, obj, soln, phd = PH.solve(build_scen_tree(),
             create_model,
             PH.ScalarPenaltyParameter(25.0),
             opt=Ipopt.Optimizer,
             opt_args=(print_level=1,tol=1e-12),
             atol=1e-6,
             rtol=1e-8,
             max_iter=2,
             report=1,
             timing=false,
             warm_start=false,
             subproblem_callbacks=[my_spcb]
            )
    @test ext[:check] == 1
    @test ext[:sp_check] == 1
end