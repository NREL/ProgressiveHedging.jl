@testset "Proportional penalty" begin
    # NOTE: I just copy pasted a bunch of stuff here to just test if this
    # doesn't throw an exception - need to refine later on.
    st = build_scen_tree()

    js = create_model(PH.scid(0))
    org_obj_func = JuMP.objective_function(js.model, JuMP.QuadExpr)

    vid_name_map = PH.report_variable_info(js, st)
    @test length(vid_name_map) == length(JuMP.all_variables(js.model))
    for (vid, vname) in pairs(vid_name_map)
        if vid.stage == PH.stid(1)
            @test occursin("x", vname)
        elseif vid.stage == PH.stid(2)
            @test vname == "y"
        else
            @test occursin("z", vname)
        end
    end

    ref_map = invert_map(js.vars)
    observed_vids = Set{PH.VariableID}()
    for var in JuMP.all_variables(js.model)
        vid = ref_map[var]
        @test !(vid in observed_vids)
        push!(observed_vids, vid)
    end
    @test length(observed_vids) == length(JuMP.all_variables(js.model))

    (br_vids, lf_vids) = PH._split_variables(st, collect(keys(vid_name_map)))

    sts = PH.solve(js)
    @test sts == MOI.LOCALLY_SOLVED
    @test sts == JuMP.termination_status(js.model)
    @test PH.objective_value(js) == JuMP.objective_value(js.model)
    org_obj_val = PH.objective_value(js)

    vals = PH.report_values(js, collect(keys(vid_name_map)))
    @test length(vals) == length(JuMP.all_variables(js.model))
    for var in JuMP.all_variables(js.model)
        @test JuMP.value(var) == vals[ref_map[var]]
    end

    r = PH.ProportionalPenaltyParameter(10.0)
    rhalf = 0.5 * 10.0
    PH.add_ph_objective_terms(js, br_vids, r) # Want to see if this works
end