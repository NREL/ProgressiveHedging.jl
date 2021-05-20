
@testset "Callback Termination" begin
    function my_term_cb(ext::Dict{Symbol,Any},
                        phd::PH.PHData,
                        winf::PH.WorkerInf,
                        niter::Int
                        )::Bool
        return niter < 5
    end

    (n, err, rerr, obj, soln, phd) = PH.solve(PH.two_stage_tree(2),
                                              two_stage_model,
                                              PH.ScalarPenaltyParameter(2.0),
                                              atol=1e-8,
                                              rtol=1e-12,
                                              max_iter=500,
                                              timing=false,
                                              warm_start=false,
                                              callbacks=[PH.Callback(my_term_cb)]
                                              )

    @test err > 1e-8
    @test rerr > 1e-12
    @test n == 5
end

@testset "Callback Subproblem" begin

    struct TestSubproblem <: PH.AbstractSubproblem
        scenario::PH.ScenarioID
        names::Dict{PH.VariableID,PH.VariableInfo}
        values::Dict{PH.VariableID,Float64}
    end

    function create_test(scen::PH.ScenarioID)::TestSubproblem
        return TestSubproblem(scen,
                              Dict{PH.VariableID,PH.VariableInfo}(),
                              Dict{PH.VariableID,Float64}())
    end

    function PH.add_ph_objective_terms(ts::TestSubproblem,
                                       vids::Vector{PH.VariableID},
                                       r::Union{Float64,
                                                Dict{VariableID,Float64}},
                                       )::Nothing
        return
    end

    function PH.objective_value(ts::TestSubproblem)::Float64
        return 0.0
    end

    function PH.report_values(ts::TestSubproblem,
                              vars::Vector{PH.VariableID},
                              )::Dict{PH.VariableID,Float64}
        vals = Dict{PH.VariableID,Float64}()
        for vid in vars
            vals[vid] = ts.values[vid]
        end
        return vals
    end

    function PH.report_variable_info(ts::TestSubproblem,
                                     st::ScenarioTree
                                     )::Dict{VariableID,PH.VariableInfo}

        for node in PH.scenario_nodes(st, ts.scenario)
            stid = PH.stage(node)
            stage = PH.value(stid)
            vid = PH.VariableID(ts.scenario, stid, PH.Index(0))
            ts.names[vid] = PH.VariableInfo(string('a' + stage - 1), false)
            ts.values[vid] = rand()
        end
        
        return ts.names
    end

    function PH.solve(ts::TestSubproblem)::MOI.TerminationStatusCode
        return MOI.OPTIMAL
    end

    function PH.update_ph_terms(ts::TestSubproblem,
                                w_vals::Dict{PH.VariableID,Float64},
                                xhat_vals::Dict{VariableID,Float64}
                                )::Nothing
        return
    end

    function to_apply(ts::TestSubproblem, set_values::Dict{VariableID,Float64})
        for (vid, value) in pairs(set_values)
            ts.values[vid] = value
        end
        return
    end

    function my_test_cb(ext::Dict{Symbol,Any},
                        phd::PH.PHData,
                        winf::PH.WorkerInf,
                        niter::Int
                        )::Bool

        if niter == 1

            vid0 = PH.VariableID(PH.ScenarioID(0), PH.StageID(1), PH.Index(0))
            val1 = PH.branch_value(phd, PH.ScenarioID(1), PH.StageID(1), PH.Index(0))
            values = Dict(vid0 => val1)
            ext[:value] = val1
            ext[:iter] = niter

            PH.apply_to_subproblem(to_apply,
                                   phd,
                                   winf,
                                   PH.ScenarioID(0),
                                   (values,)
                                   )
        end

        return true
    end

    (n, err, rerr, obj, soln, phd) = PH.solve(PH.two_stage_tree(2),
                                              create_test,
                                              PH.ScalarPenaltyParameter(2.0),
                                              atol=1e-8,
                                              rtol=1e-12,
                                              max_iter=500,
                                              timing=false,
                                              warm_start=false,
                                              callbacks=[PH.Callback(my_test_cb)]
                                              )

    @test err == 0.0
    @test rerr == 0.0
    @test obj == 0.0
    @test n == 3

    cb_ext = phd.callbacks[1].ext 
    value = cb_ext[:value]
    @test PH.branch_value(phd, PH.ScenarioID(0), PH.StageID(1), PH.Index(0)) == value
    @test PH.branch_value(phd, PH.ScenarioID(1), PH.StageID(1), PH.Index(0)) == value
    @test cb_ext[:iter] == 1

end

@testset "Variable Fixing Callback" begin

    phd = fake_phdata(3, 4; add_leaves=false)
    winf = fake_worker_info()
    nscen = length(PH.scenarios(phd))
    lag = 2

    PH.add_callback(phd, PH.variable_fixing(lag=lag))

    phd.scenario_map[PH.scid(0)].branch_vars[PH.VariableID(PH.scid(0), PH.stid(1), PH.index(1))] = -1.0
    PH.compute_and_save_xhat(phd)

    for niter in 1:(2*lag*nscen)
        PH._execute_callbacks(phd, winf, niter)
    end
    cb_ext = phd.callbacks[1].ext

    for (xhid, xhat) in pairs(PH.consensus_variables(phd))
        if PH.name(phd, xhid) == "a1"
            @test !(xhid in cb_ext[:fixed])
        else
            @test xhid in cb_ext[:fixed]
        end
    end

    msg_count = 0
    while isready(winf.inputs[1])

        msg = take!(winf.inputs[1])
        msg_count += 1

        @test typeof(msg) == PH.SubproblemAction
        @test string(msg.action) == "fix_variables"

        s = msg.scen
        value_dict = msg.args[1]

        for (vid, value) in pairs(value_dict)
            xhid = PH.convert_to_xhat_id(phd, vid)
            xhat = phd.xhat[xhid]
            @test value == PH.value(xhat)
            @test xhid in cb_ext[:fixed]
        end
    end

    @test msg_count == nscen
end

@testset "Mean Deviation Callback" begin

    phd = fake_phdata(3, 4; add_leaves=false)
    winf = fake_worker_info()
    nscen = length(PH.scenarios(phd))
    tol = 1e-8

    PH.add_callback(phd, PH.mean_deviation(tol=tol, save_deviations=true))
    PH.compute_and_save_xhat(phd)
    user_continue = PH._execute_callbacks(phd, winf, 1)

    @test user_continue == false
    md_ext = PH.get_callback_ext(phd, "mean_deviation")
    @test isapprox(md_ext[:deviations][1], 0.0, atol=1e-8)
    @test md_ext[:tol] == tol

    phd.scenario_map[PH.scid(0)].branch_vars[PH.VariableID(PH.scid(0), PH.stid(1), PH.index(1))] = 4.0
    PH.compute_and_save_xhat(phd)
    user_continue = PH._execute_callbacks(phd, winf, 2)

    @test user_continue == true
    @test isapprox(md_ext[:deviations][2], 0.6)

    phd = fake_phdata(3, 4; add_leaves=false)
    phd.scenario_map[PH.scid(0)].branch_vars[PH.VariableID(PH.scid(0), PH.stid(1), PH.index(1))] = 4.0
    PH.add_callback(phd, PH.mean_deviation(tol=1.0, save_deviations=false))
    PH.compute_and_save_xhat(phd)
    user_continue = PH._execute_callbacks(phd, winf, 1)

    @test user_continue == false

end

@testset "Subproblem Callback" begin
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
