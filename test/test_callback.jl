
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
