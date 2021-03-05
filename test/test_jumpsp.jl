@testset "Scenario Form" begin
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

    r = PH.ScalarPenaltyParameter(10.0)
    rhalf = 0.5 * 10.0
    PH.add_ph_objective_terms(js, br_vids, r)
    ph_obj_func = JuMP.objective_function(js.model, JuMP.QuadExpr)

    diff = ph_obj_func - org_obj_func
    JuMP.drop_zeros!(diff)

    @test length(JuMP.linear_terms(diff)) == 0
    @test length(JuMP.quad_terms(diff)) == (4 * length(br_vids))
    for qt in JuMP.quad_terms(diff)
        coef = qt[1]
        @test (isapprox(coef, rhalf) || isapprox(coef, -r.value) || isapprox(coef, 1.0))
    end

    w_vals = Dict{PH.VariableID,Float64}()
    for (k,w) in enumerate(keys(js.w_vars))
        w_vals[w] = k * rand()
    end
    xhat_vals = Dict{PH.VariableID,Float64}()
    for (k,xhat) in enumerate(keys(js.xhat_vars))
        xhat_vals[xhat] = k * rand()
    end
    PH.update_ph_terms(js, w_vals, xhat_vals)

    PH.warm_start(js)
    sts = PH.solve(js)
    @test sts == MOI.LOCALLY_SOLVED
    @test org_obj_val != PH.objective_value(js)

    for (wid, wref) in pairs(js.w_vars)
        @test JuMP.value(wref) == w_vals[wid]
    end
    for (xhid, xhref) in pairs(js.xhat_vars)
        @test JuMP.value(xhref) == xhat_vals[xhid]
    end
end

@testset "Extensive Form" begin
end

@testset "Penalties" begin
    st = build_scen_tree()

    js = create_model(PH.scid(0))

    vid_name_map = PH.report_variable_info(js, st)

    (br_vids, lf_vids) = PH._split_variables(st, collect(keys(vid_name_map)))

    r = PH.ScalarPenaltyParameter(10.0)
    @test (typeof(PH.add_ph_objective_terms(js, br_vids, r)) <: Dict{PH.VariableID, Float64})

    r = PH.ProportionalPenaltyParameter(10.0)
    @test (typeof(PH.add_ph_objective_terms(js, br_vids, r)) <: Dict{PH.VariableID, Float64})

    sts = PH.solve(js)
end