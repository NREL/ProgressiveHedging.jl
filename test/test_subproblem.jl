@testset "Unimplemented Error" begin

    struct InterfaceFunction
        f::Function
        args::Tuple
    end

    function IF(f::Function, args...)
        return InterfaceFunction(f, args)
    end

    struct Unimplemented <: PH.AbstractSubproblem
    end

    to_test = [
        IF(PH.add_ph_objective_terms, Vector{PH.VariableID}(), 2.25),
        IF(PH.objective_value),
        IF(PH.report_values, Vector{PH.VariableID}()),
        IF(PH.report_variable_info, build_scen_tree()),
        IF(PH.solve),
        IF(PH.update_ph_terms, Dict{PH.VariableID,Float64}(), Dict{PH.VariableID,Float64}()),
        IF(PH.warm_start),
        IF(PH.report_penalty_info, PH.ProportionalPenaltyParameter),
        IF(PH.add_lagrange_terms, Vector{VariableID}()),
        IF(PH.update_lagrange_terms, Dict{VariableID,Float64}()),
    ]

    subprob = Unimplemented()
    for interface_function in to_test
        @test_throws PH.UnimplementedError begin
            interface_function.f(subprob, interface_function.args...)
        end
    end

    @test_throws PH.UnimplementedError begin
        PH.ef_copy_model(JuMP.Model(),
                         subprob,
                         PH.scid(0),
                         build_scen_tree(),
                         Dict{PH.NodeID,Any}()
                         )
    end
    @test_throws PH.UnimplementedError begin
        PH.ef_node_dict_constructor(typeof(subprob))
    end
end

@testset "Scenario Form" begin
    st = build_scen_tree()

    js = create_model(PH.scid(0))
    org_obj_func = JuMP.objective_function(js.model, JuMP.QuadExpr)

    vid_name_map = PH.report_variable_info(js, st)
    @test length(vid_name_map) == length(JuMP.all_variables(js.model))
    for (vid, vinfo) in pairs(vid_name_map)
        if vid.stage == PH.stid(1)
            @test occursin("x", vinfo.name)
        elseif vid.stage == PH.stid(2)
            @test vinfo.name == "y"
        else
            @test occursin("z", vinfo.name)
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
    PH.add_ph_objective_terms(js, br_vids, r.value)
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
    #TODO: Make tests for this case
end

@testset "Penalties" begin
    st = build_scen_tree()

    # Scalar Penalty
    js = create_model(PH.scid(0))
    vid_name_map = PH.report_variable_info(js, st)
    (br_vids, lf_vids) = PH._split_variables(st, collect(keys(vid_name_map)))
    obj = JuMP.objective_function(js.model)

    PH.add_ph_objective_terms(js, br_vids, 10.0)

    ph_obj_func = JuMP.objective_function(js.model, JuMP.QuadExpr)
    diff = ph_obj_func - obj
    JuMP.drop_zeros!(diff)

    @test length(JuMP.linear_terms(diff)) == 0
    @test length(JuMP.quad_terms(diff)) == (4 * length(br_vids))
    for vid in br_vids
        x_ref = js.vars[vid]
        w_ref = js.w_vars[vid]
        xhat_ref = js.xhat_vars[vid]
        for (c, v1, v2) in JuMP.quad_terms(diff)
            if (x_ref == v1 && x_ref == v2) || (xhat_ref == v1 && xhat_ref == v2)
                @test isapprox(c, 5.0)
            elseif (x_ref == v1 && xhat_ref == v2) || (xhat_ref == v1 && x_ref == v2)
                @test isapprox(c, -10.0)
            elseif (x_ref == v1 && w_ref == v2) || (w_ref == v1 && x_ref == v2)
                @test isapprox(c, 1.0)
            end
        end
    end

    # Proportional Penalty
    js = create_model(PH.scid(0))
    vid_name_map = PH.report_variable_info(js, st)
    (br_vids, lf_vids) = PH._split_variables(st, collect(keys(vid_name_map)))
    coef_dict = PH.report_penalty_info(js, br_vids, PH.ProportionalPenaltyParameter)
    obj = JuMP.objective_function(js.model)
    for (vid, coef) in pairs(coef_dict)
        ref = js.vars[vid]
        for lt in JuMP.linear_terms(obj)
            if lt[2] == ref
                @test lt[1] == coef
                break
            end
        end
        coef_dict[vid] = 10.0 * coef
    end
    PH.add_ph_objective_terms(js, br_vids, coef_dict)

    ph_obj_func = JuMP.objective_function(js.model, JuMP.QuadExpr)
    diff = ph_obj_func - obj
    JuMP.drop_zeros!(diff)

    @test length(JuMP.linear_terms(diff)) == 0
    @test length(JuMP.quad_terms(diff)) == (4 * length(br_vids))

    for vid in br_vids
        x_ref = js.vars[vid]
        w_ref = js.w_vars[vid]
        xhat_ref = js.xhat_vars[vid]
        for (c, v1, v2) in JuMP.quad_terms(diff)
            if (x_ref == v1 && x_ref == v2) || (xhat_ref == v1 && xhat_ref == v2)
                @test isapprox(c, 0.5 * coef_dict[vid])
            elseif (x_ref == v1 && xhat_ref == v2) || (xhat_ref == v1 && x_ref == v2)
                @test isapprox(c, -1.0 * coef_dict[vid])
            elseif (x_ref == v1 && w_ref == v2) || (w_ref == v1 && x_ref == v2)
                @test isapprox(c, 1.0)
            end
        end
    end

    # SEP Penalty
    js = create_model(PH.scid(0))
    vid_name_map = PH.report_variable_info(js, st)
    (br_vids, lf_vids) = PH._split_variables(st, collect(keys(vid_name_map)))
    coef_dict = PH.report_penalty_info(js, br_vids, PH.SEPPenaltyParameter)
    obj = JuMP.objective_function(js.model)
    for (vid, coef) in pairs(coef_dict)
        ref = js.vars[vid]
        for lt in JuMP.linear_terms(obj)
            if lt[2] == ref
                @test lt[1] == coef
                break
            end
        end
        coef_dict[vid] = rand() * coef
    end
    PH.add_ph_objective_terms(js, br_vids, coef_dict)

    ph_obj_func = JuMP.objective_function(js.model, JuMP.QuadExpr)
    diff = ph_obj_func - obj
    JuMP.drop_zeros!(diff)

    @test length(JuMP.linear_terms(diff)) == 0
    @test length(JuMP.quad_terms(diff)) == (4 * length(br_vids))

    for vid in br_vids
        x_ref = js.vars[vid]
        w_ref = js.w_vars[vid]
        xhat_ref = js.xhat_vars[vid]
        for (c, v1, v2) in JuMP.quad_terms(diff)
            if (x_ref == v1 && x_ref == v2) || (xhat_ref == v1 && xhat_ref == v2)
                @test isapprox(c, 0.5 * coef_dict[vid])
            elseif (x_ref == v1 && xhat_ref == v2) || (xhat_ref == v1 && x_ref == v2)
                @test isapprox(c, -1.0 * coef_dict[vid])
            elseif (x_ref == v1 && w_ref == v2) || (w_ref == v1 && x_ref == v2)
                @test isapprox(c, 1.0)
            end
        end
    end

end

@testset "Fix Variables" begin
    js = create_model(PH.scid(0))

    is_fixed = Dict{PH.VariableID,Float64}()
    is_free = Vector{PH.VariableID}()
    for vid in keys(js.vars)
        r = rand()
        if r > 0.5
            is_fixed[vid] = r
        else
            push!(is_free, vid)
        end
    end

    PH.fix_variables(js, is_fixed)

    for (vid,var) in pairs(js.vars)
        if haskey(is_fixed, vid)
            @test JuMP.is_fixed(var)
            @test JuMP.value(var) == is_fixed[vid]
        elseif vid in is_free
            @test !JuMP.is_fixed(var)
        else
            error("Vid $vid is neither fixed nor free")
        end
    end

end
