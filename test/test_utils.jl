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
                       m2::Int)
    vmap = Dict{PH.ScenarioID, Dict{PH.VariableID, String}}()
    vval = Dict{PH.ScenarioID, Dict{PH.VariableID, Float64}}()
    for k in 1:n
        scid = PH.scid(k-1)

        vars = Dict{PH.VariableID, String}()
        vals = Dict{PH.VariableID, Float64}()
        for j in 1:m1
            vid = PH.VariableID(scid, PH.stid(1), PH.index(j + k - 1))
            vars[vid] = "a$j" # convert(Float64, j)
            vals[vid] = convert(Float64, j)
        end

        for j in 1:m2
            vid = PH.VariableID(scid, PH.stid(2), PH.index(j-1))
            vars[vid] = "b$j" # convert(Float64, k*j + n)
            vals[vid] = convert(Float64, k*j + n)
        end

        vmap[scid] = vars
        vval[scid] = vals
    end
    return (vmap, vval)
end

nscen = 2
nv1 = 3
nv2 = 4
st = two_stage_tree(nscen)
(var_map, var_val) = build_var_map(nscen, nv1, nv2)

phd = PH.PHData(1.0,
                st,
                Dict{Int,Set{PH.ScenarioID}}(1=>copy(PH.scenarios(st))),
                var_map,
                TimerOutputs.TimerOutput()
                )

# Create entries for leaf variables.  This is normally done at the end of the solve call
# but since we aren't calling that here...
for (scid, sinfo) in pairs(phd.scenario_map)
    for vid in keys(sinfo.branch_vars)
        xhid = PH.convert_to_xhat_id(phd, vid)
        sinfo.branch_vars[vid] = var_val[scid][vid]
        phd.xhat[xhid].value = var_val[scid][vid]
    end
    for vid in keys(sinfo.leaf_vars)
        xhid = PH.convert_to_xhat_id(phd, vid)
        sinfo.leaf_vars[vid] = var_val[scid][vid]
        phd.xhat[xhid] = PH.HatVariable(var_val[scid][vid], vid)
    end
end

@testset "Accessor Utilities" begin
    scid = PH.scid(0)
    stid = PH.stid(1)
    index = PH.index(2)
    vid = PH.VariableID(scid, stid, index)
    @test PH.name(phd, vid) == "a2"
    val = convert(Float64, PH._value(index) - PH._value(scid))
    @test PH.value(phd, vid) == val
    @test PH.value(phd, scid, stid, index) == val
    @test PH.branch_value(phd, vid) == val
    @test PH.branch_value(phd, scid, stid, index) == val

    scid = PH.scid(1)
    stid = PH.stid(2)
    index = PH.index(3)
    vid = PH.VariableID(scid, stid, index)
    @test PH.name(phd, vid) == "b4"
    val = convert(Float64, nscen + (PH._value(index) + 1)*(PH._value(scid) + 1))
    @test PH.value(phd, vid) == val
    @test PH.value(phd, scid, stid, index) == val
    @test PH.leaf_value(phd, vid) == val
    @test PH.leaf_value(phd, scid, stid, index) == val
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
end
