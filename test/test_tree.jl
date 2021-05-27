
@testset "Scenario Tree Errors" begin
    st = PH.ScenarioTree()
    @test_throws(ErrorException, PH.add_leaf(st, PH.root(st), -1.0))
end

@testset "Scenario Tree Functions" begin

    # First stage -- Creates root/first stage node automatically
    st = PH.ScenarioTree()

    # Second stage
    n1 = PH.add_node(st, PH.root(st))
    n2 = PH.add_node(st, PH.root(st))

    # Third stage
    sc0 = PH.add_leaf(st, n1, 0.25*0.75)
    sc1 = PH.add_leaf(st, n1, 0.75*0.75)
    sc2 = PH.add_leaf(st, n2, 0.25)

    @test length(n1.children) == 2
    (n3, n4) = n1.children
    if n3.id > n4.id
        temp = n4
        n4 = n3
        n3 = temp
    end
    @test length(n2.children) == 1
    n5 = first(n2.children) # only element in the set

    @test PH.last_stage(st) == PH.StageID(3)
    @test PH.is_leaf(st.root) == false
    @test PH.is_leaf(n1) == false
    @test PH.is_leaf(n2) == true # only having 1 child scenario means this is actually a leaf
    @test PH.is_leaf(n3) == true
    @test PH.is_leaf(n4) == true
    @test PH.is_leaf(n5) == true

    @test st.prob_map[sc0] == 0.25*0.75
    @test st.prob_map[sc1] == 0.75*0.75
    @test st.prob_map[sc2] == 0.25

    nodes = [st.root, n1, n2, n3, n4, n5]
    for n in nodes
        @test st.tree_map[n.id] == n
    end

    @test PH.scenarios(st) == Set([sc0, sc1, sc2])
    @test PH.scenario_bundle(st.root) == Set([sc0, sc1, sc2])
    @test PH.scenario_bundle(n1) == Set([sc0, sc1])
    @test PH.scenario_bundle(n2) == Set([sc2])
    @test PH.scenario_bundle(n3) == Set([sc0])
    @test PH.scenario_bundle(n4) == Set([sc1])
    @test PH.scenario_bundle(n5) == Set([sc2])

end

@testset "Scenario Tree Utilities" begin
    N = 10
    p = rand(N)
    p /= sum(p)
    st = PH.two_stage_tree(p)

    @test PH.last_stage(st) == PH.stid(2)
    @test length(st.tree_map) == N + 1
    for (scen, prob) in pairs(st.prob_map)
        @test prob == p[PH.value(scen) + 1]
    end

    st = PH.two_stage_tree(N)
    @test PH.last_stage(st) == PH.stid(2)
    @test length(st.tree_map) == N + 1
    for (scen, prob) in pairs(st.prob_map)
        @test prob == 1.0 / 10.0
    end
end
