@testset "Struct accessors" begin
    @test PH.value(PH.ScenarioID(1)) == 1
    @test PH.value(PH.StageID(2)) == 2
    @test PH.value(PH.Index(3)) == 3
    @test PH.value(PH.NodeID(4)) == 4
end

@testset "Convenience constructors" begin
    @test PH.scid(1) == PH.ScenarioID(1)
    @test PH.stid(1) == PH.StageID(1)
    @test PH.index(1) == PH.Index(1)
end

@testset "Struct less than operators" begin
    @test PH.NodeID(3) < PH.NodeID(7)
    @test PH.scid(0) < PH.scid(2)
    @test PH.stid(1) < PH.stid(4)
    @test PH._increment(PH.stid(1)) == PH.stid(2)
    @test PH.index(10) < PH.index(16)
    @test PH._increment(PH.index(15)) == PH.index(16)

    uvid1 = PH.VariableID(PH.scid(4), PH.stid(1), PH.index(347))
    uvid2 = PH.VariableID(PH.scid(0), PH.stid(2), PH.index(2))
    uvid3 = PH.VariableID(PH.scid(1), PH.stid(2), PH.index(2))
    uvid4 = PH.VariableID(PH.scid(1), PH.stid(2), PH.index(3))
    @test uvid1 < uvid2
    @test uvid2 < uvid3
    @test uvid3 < uvid4

    xhid1 = PH.XhatID(PH.NodeID(0), PH.Index(4))
    xhid2 = PH.XhatID(PH.NodeID(1), PH.Index(2))
    xhid3 = PH.XhatID(PH.NodeID(1), PH.Index(3))
    @test xhid1 < xhid2
    @test xhid2 < xhid3
end

@testset "Consensus variable functions" begin
    tv = PH.HatVariable(true)
    @test PH.is_integer(tv)
    vid = PH.VariableID(PH.scid(3), PH.stid(2), PH.index(392))
    PH.add_variable(tv, vid)
    @test PH.variables(tv) == Set([vid])
    rv = rand()
    PH.set_value(tv, rv)
    @test tv.value == rv
    @test PH.value(tv) == rv
end

@testset "Convenience functions" begin
    st = two_stage_tree(3)
    @test length(st.tree_map) == 4
    @test length(st.prob_map) == 3
    @test isapprox(sum(values(st.prob_map)), 1.0)

    p = [0.8, 0.2]
    st = two_stage_tree(p)
    @test st.prob_map[PH.scid(0)] == p[1]
    @test st.prob_map[PH.scid(1)] == p[2]
end

nv1 = 3
nv2 = 4
phd = fake_phdata(nv1, nv2)
nscen = length(PH.scenarios(phd))

@testset "Accessor Utilities" begin
    scid = PH.scid(0)
    stid = PH.stid(1)
    index = PH.index(2)
    vid = PH.VariableID(scid, stid, index)
    @test PH.name(phd, vid) == "a2"
    val = convert(Float64, PH.value(index) - PH.value(scid))
    @test PH.value(phd, vid) == val
    @test PH.value(phd, scid, stid, index) == val
    @test PH.branch_value(phd, vid) == val
    @test PH.branch_value(phd, scid, stid, index) == val

    scid = PH.scid(1)
    stid = PH.stid(2)
    index = PH.index(3)
    vid = PH.VariableID(scid, stid, index)
    @test PH.name(phd, vid) == "b4"
    val = convert(Float64, nscen + (PH.value(index) + 1)*(PH.value(scid) + 1))
    @test PH.value(phd, vid) == val
    @test PH.value(phd, scid, stid, index) == val
    @test PH.leaf_value(phd, vid) == val
    @test PH.leaf_value(phd, scid, stid, index) == val

    @test_throws ErrorException PH.name(phd, PH.VariableID(PH.scid(8303), stid, index))

    @test scenario_tree(phd) === phd.scenario_tree

    # TODO: capture output of below and compare it to the string from the IOBuffer
    print_timing(phd)
    io = IOBuffer()
    print_timing(io, phd)
    @test length(String(take!(io))) > 0

end

@testset "Conversion utilities" begin

    # Branch variables
    for i in 1:nv1
        vid1 = PH.VariableID(PH.scid(0), PH.stid(1), PH.index(i))
        vid2 = PH.VariableID(PH.scid(1), PH.stid(1), PH.index(i+1))
        xhid = PH.convert_to_xhat_id(phd, vid1)
        @test PH.convert_to_xhat_id(phd, vid2) == xhid
        @test PH.convert_to_variable_ids(phd, xhid) == Set{PH.VariableID}([vid1, vid2])
    end

    # Leaf variables
    for j in 1:nv2
        vid1 = PH.VariableID(PH.scid(0), PH.stid(2), PH.index(j-1))
        vid2 = PH.VariableID(PH.scid(1), PH.stid(2), PH.index(j-1))
        @test PH.convert_to_variable_ids(phd, PH.convert_to_xhat_id(phd, vid1)) == Set{PH.VariableID}([vid1])
        @test PH.convert_to_variable_ids(phd, PH.convert_to_xhat_id(phd, vid2)) == Set{PH.VariableID}([vid2])
        @test PH.convert_to_xhat_id(phd, vid1) != PH.convert_to_xhat_id(phd, vid2)
    end

end

@testset "PH variable accessors" begin
    scid = PH.scid(0)
    stid = PH.stid(1)
    index = PH.index(1)
    vid = PH.VariableID(scid, stid, index)
    rval = rand()

    phd.scenario_map[scid].w_vars[vid] = rval
    @test PH.w_value(phd, vid) == rval
    @test PH.w_value(phd, scid, stid, index) == rval

    rval = rand()
    xhid = PH.convert_to_xhat_id(phd, vid)

    phd.xhat[xhid].value = rval
    @test PH.xhat_value(phd, xhid) == rval
    @test PH.xhat_value(phd, vid) == rval
    @test PH.xhat_value(phd, scid, stid, index) == rval

    @test PH.is_leaf(phd, xhid) == false
    vid = PH.VariableID(PH.scid(0), PH.stid(2), PH.index(0))
    xhid = PH.convert_to_xhat_id(phd, vid)
    @test PH.is_leaf(phd, xhid) == true
end
