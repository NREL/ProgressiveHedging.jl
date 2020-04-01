@testset "Struct accessors" begin
    @test PH._value(PH.ScenarioID(1)) == 1
    @test PH._value(PH.StageID(2)) == 2
    @test PH._value(PH.Index(3)) == 3
    @test PH._value(PH.NodeID(4)) == 4
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

    vid1 = PH.VariableID(PH.stid(1), PH.index(5))
    vid2 = PH.VariableID(PH.stid(2), PH.index(2))
    vid3 = PH.VariableID(PH.stid(2), PH.index(3))
    @test vid1 < vid2
    @test vid2 < vid3

    uvid1 = PH.UniqueVariableID(PH.scid(4), PH.stid(1), PH.index(347))
    uvid2 = PH.UniqueVariableID(PH.scid(0), PH.stid(2), PH.index(2))
    uvid3 = PH.UniqueVariableID(PH.scid(1), PH.stid(2), PH.index(2))
    uvid4 = PH.UniqueVariableID(PH.scid(1), PH.stid(2), PH.index(3))
    @test uvid1 < uvid2
    @test uvid2 < uvid3
    @test uvid3 < uvid4

    xhid1 = PH.XhatID(PH.NodeID(0), PH.Index(4))
    xhid2 = PH.XhatID(PH.NodeID(1), PH.Index(2))
    xhid3 = PH.XhatID(PH.NodeID(1), PH.Index(3))
    @test xhid1 < xhid2
    @test xhid2 < xhid3
end

@testset "Convenience functions" begin
    st = two_stage_tree(3)
    @test length(st.tree_map) == 4
    @test length(st.prob_map) == 3
    @test isapprox(sum(values(st.prob_map)), 1.0)

    p = [0.8, 0.2]
    st = two_stage_tree(2, pvect=p)
    @test st.prob_map[PH.scid(0)] == p[1]
    @test st.prob_map[PH.scid(1)] == p[2]
end

function build_var_map(n::Int,
                       m1::Int,
                       m2::Int,
                       )::Dict{PH.ScenarioID, Dict{PH.VariableID, PH.VariableInfo}}

    vmap = Dict{PH.ScenarioID, Dict{PH.VariableID, PH.VariableInfo}}()
    for k in 1:n
        scid = PH.scid(k-1)

        vars = Dict{PH.VariableID, PH.VariableInfo}()
        for j in 1:m1
            vid = PH.VariableID(PH.stid(1), PH.index(j-1))
            vars[vid] = PH.VariableInfo(Future(),
                                        "a$j",
                                        PH.NodeID(0),
                                        convert(Float64, j))
        end

        for j in 1:m2
            vid = PH.VariableID(PH.stid(2), PH.index(j-1))
            vars[vid] = PH.VariableInfo(Future(),
                                        "b$j",
                                        PH.NodeID(k),
                                        convert(Float64, k*j + n))
        end

        vmap[scid] = vars
    end
    return vmap
end

nscen = 2
nv1 = 3
nv2 = 4
st = two_stage_tree(nscen)
var_map = build_var_map(nscen, nv1, nv2)
phd = PH.PHData(1.0,
                st,
                Dict{PH.ScenarioID, Int}([PH.scid(k)=>1 for k in 0:nscen-1]),
                st.prob_map,
                Dict{PH.ScenarioID, Future}([PH.scid(k)=>Future() for k in 0:nscen-1]),
                var_map,
                PH.Indexer(),
                TimerOutputs.TimerOutput()
                )
             
@testset "Accessor Utilities" begin
    scid = PH.scid(0)
    stid = PH.stid(1)
    index = PH.index(1)
    vid = PH.VariableID(stid, index)
    @test PH.name(phd, scid, vid) == "a2"
    val = convert(Float64, PH._value(index) + 1)
    @test PH.value(phd, scid, vid) == val
    @test PH.value(phd, scid, stid, index) == val
    @test PH.branch_value(phd, scid, vid) == val
    @test PH.branch_value(phd, scid, stid, index) == val

    scid = PH.scid(1)
    stid = PH.stid(2)
    index = PH.index(3)
    vid = PH.VariableID(stid, index)
    @test PH.name(phd, scid, vid) == "b4"
    val = convert(Float64, nscen + (PH._value(index) + 1)*(PH._value(scid) + 1))
    @test PH.value(phd, scid, vid) == val
    @test PH.value(phd, scid, stid, index) == val
    @test PH.leaf_value(phd, scid, vid) == val
    @test PH.leaf_value(phd, scid, stid, index) == val
end

@testset "Conversion utilities" begin
    vid = PH.VariableID(PH.stid(2), PH.index(1))
    xhid = PH.XhatID(PH.NodeID(1), PH.index(1))
    @test PH.convert_to_variable_id(phd, xhid) == (PH.scid(0), vid)
    @test PH.convert_to_xhat_id(phd, PH.scid(0), vid) == xhid
end

@testset "PH variable accessors" begin
    stid = PH.stid(1)
    index = PH.index(0)
    vid = PH.VariableID(stid, index)
    rval = rand()
    scid = PH.scid(0)

    phd.scenario_map[scid].W[vid].value = rval
    @test PH.w_value(phd, scid, vid) == rval
    @test PH.w_value(phd, scid, stid, index) == rval

    rval = rand()
    nid = PH.NodeID(0)
    index = PH.index(0)
    xhid = PH.XhatID(nid, index)

    phd.Xhat[xhid].value = rval
    @test PH.xhat_value(phd, xhid) == rval
    @test PH.xhat_value(phd, scid, vid) == rval
    @test PH.xhat_value(phd, scid, stid, index) == rval
end
