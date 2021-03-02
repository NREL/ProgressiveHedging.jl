@testset "Proportional penalty" begin
    st = build_scen_tree()

    js = create_model(PH.scid(0))

    vid_name_map = PH.report_variable_info(js, st)

    (br_vids, lf_vids) = PH._split_variables(st, collect(keys(vid_name_map)))

    sts = PH.solve(js)

    r = PH.ScalarPenaltyParameter(10.0)
    @test (PH.add_ph_objective_terms(js, br_vids, r) === nothing)

    r = PH.ProportionalPenaltyParameter(10.0)
    @test (PH.add_ph_objective_terms(js, br_vids, r) === nothing)
end