
@testset "Scenario Tree Functions" begin
    # First stage
    root = StructuredModel(num_scenarios=2)

    # Second stage
    m1 = StructuredModel(parent=root, id=1, prob=0.75, num_scenarios=2)
    m2 = StructuredModel(parent=root, id=2, prob=0.25, num_scenarios=1)

    # Third stage
    m3 = StructuredModel(parent=m1, id=1, prob=0.25)
    m4 = StructuredModel(parent=m1, id=2, prob=0.75)
    m5 = StructuredModel(parent=m2, id=1, prob=1.0)

    # Build up scenario tree
    st = PH.ScenarioTree(root)
    n1 = PH._add_node(st, m1)
    n2 = PH._add_node(st, m2)
    n3 = PH._add_node(st, m3)
    PH._create_scenario(st, m3, 0.25*0.75)
    n4 = PH._add_node(st, m4)
    PH._create_scenario(st, m4, 0.75*0.75)
    n5 = PH._add_node(st, m5)
    PH._create_scenario(st, m5, 0.25*1.0)

    @test PH.translate(st, n1.id) == PH.translate(st, n1) == m1
    @test PH.translate(st, n2.id) == PH.translate(st, n2) == m2
    @test PH.translate(st, n3.id) == PH.translate(st, n3) == m3
    @test PH.translate(st, n4.id) == PH.translate(st, n4) == m4
    @test PH.translate(st, n5.id) == PH.translate(st, n5) == m5

    @test PH.translate(st, m1) == n1
    @test PH.translate(st, m2) == n2
    @test PH.translate(st, m3) == n3
    @test PH.translate(st, m4) == n4
    @test PH.translate(st, m5) == n5

    @test PH.last_stage(st) == PH.StageID(3)
    @test PH.is_leaf(st.root) == false
    @test PH.is_leaf(n1) == false
    # only having 1 child scenario means this is actually a leaf
    @test PH.is_leaf(n2) == true
    @test PH.is_leaf(n3) == true
    @test PH.is_leaf(n4) == true
    @test PH.is_leaf(n5) == true

    @test st.prob_map[PH.ScenarioID(0)] == 0.25*0.75
    @test st.prob_map[PH.ScenarioID(1)] == 0.75*0.75
    @test st.prob_map[PH.ScenarioID(2)] == 0.25

    nodes = [st.root, n1, n2, n3, n4, n5]
    for n in nodes
        @test st.tree_map[n.id] == n
        @test n.id in st.stage_map[n.stage]
    end

    sc0 = PH.ScenarioID(0)
    sc1 = PH.ScenarioID(1)
    sc2 = PH.ScenarioID(2)

    @test PH.scenarios(st) == Set([sc0, sc1, sc2])
    @test PH.scenario_bundle(st.root) == Set([sc0, sc1, sc2])
    @test PH.scenario_bundle(n1) == Set([sc0, sc1])
    @test PH.scenario_bundle(n2) == Set([sc2])
    @test PH.scenario_bundle(n3) == Set([sc0])
    @test PH.scenario_bundle(n4) == Set([sc1])
    @test PH.scenario_bundle(n5) == Set([sc2])
end

# @testset "Scenario Process Assignment" begin
#     @test true
# end

@testset "Full StructJuMP Setup" begin
    sjm = build_sj_model()

    stree = PH.build_scenario_tree(sjm)

    @test PH.last_stage(stree) == PH.StageID(3)

    sc0 = PH.ScenarioID(0)
    sc1 = PH.ScenarioID(1)
    sc2 = PH.ScenarioID(2)
    sc3 = PH.ScenarioID(3)

    @test PH.scenarios(stree) == Set([sc0, sc1, sc2, sc3])
    @test isapprox(sum(values(stree.prob_map)), 1.0)
    @test isapprox(stree.prob_map[sc0], 0.5*0.75)
    @test isapprox(stree.prob_map[sc1], 0.5*0.25)
    @test isapprox(stree.prob_map[sc2], 0.5*0.75)
    @test isapprox(stree.prob_map[sc3], 0.5*0.25)
    
    (smods, sp_map, v_map) = PH.convert_to_submodels(sjm,
                                                     optimizer(),
                                                     stree,
                                                     JuMP.Model
                                                     )

    for (scid, mfuture) in pairs(smods)
        model = fetch(mfuture)
        @test length(JuMP.all_variables(model)) == 6
        ncons = 0
        for (ftype,stype) in JuMP.list_of_constraint_types(model)
            ncons += JuMP.num_constraints(model, ftype, stype)
        end
        @test ncons == 7
    end
end

@testset "StructJuMP Scenario Tree Setup" begin
    sm = build_sj_model()
    st = PH.build_scenario_tree(sm)

    @test PH.last_stage(st) == PH.StageID(3)

    sc0 = PH.ScenarioID(0)
    sc1 = PH.ScenarioID(1)
    sc2 = PH.ScenarioID(2)
    sc3 = PH.ScenarioID(3)

    @test PH.scenarios(st) == Set([sc0, sc1, sc2, sc3])
    @test isapprox(sum(values(st.prob_map)), 1.0)
    @test isapprox(st.prob_map[sc0], 0.5*0.75)
    @test isapprox(st.prob_map[sc1], 0.5*0.25)
    @test isapprox(st.prob_map[sc2], 0.5*0.75)
    @test isapprox(st.prob_map[sc3], 0.5*0.25)

    (smods, sp_map, v_map) = PH.build_submodels(st,
                                                create_model, (),
                                                variable_dict(),
                                                optimizer(),
                                                JuMP.Model,
                                                TimerOutputs.TimerOutput())

    for (scid, mfuture) in pairs(smods)
        model = fetch(mfuture)
        @test length(JuMP.all_variables(model)) == 6
        ncons = 0
        for (ftype,stype) in JuMP.list_of_constraint_types(model)
            ncons += JuMP.num_constraints(model, ftype, stype)
        end
        @test ncons == 7
    end
end

@testset "Scenario Tree Direct Setup" begin
    st = build_scen_tree()

    @test PH.last_stage(st) == PH.StageID(3)

    sc0 = PH.ScenarioID(0)
    sc1 = PH.ScenarioID(1)
    sc2 = PH.ScenarioID(2)
    sc3 = PH.ScenarioID(3)

    @test PH.scenarios(st) == Set([sc0, sc1, sc2, sc3])
    @test isapprox(sum(values(st.prob_map)), 1.0)
    @test isapprox(st.prob_map[sc0], 0.5*0.75)
    @test isapprox(st.prob_map[sc1], 0.5*0.25)
    @test isapprox(st.prob_map[sc2], 0.5*0.75)
    @test isapprox(st.prob_map[sc3], 0.5*0.25)

    (smods, sp_map, v_map) = PH.build_submodels(st,
                                                create_model, (),
                                                variable_dict(),
                                                optimizer(),
                                                JuMP.Model,
                                                TimerOutputs.TimerOutput())

    for (scid, mfuture) in pairs(smods)
        model = fetch(mfuture)
        @test length(JuMP.all_variables(model)) == 6
        ncons = 0
        for (ftype,stype) in JuMP.list_of_constraint_types(model)
            ncons += JuMP.num_constraints(model, ftype, stype)
        end
        @test ncons == 7
    end
end
