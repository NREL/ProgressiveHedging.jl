function name(phd::PHData, scen::ScenarioID, vid::VariableID)::String
    vinfo = retrieve_variable(phd.scenario_map[scen], vid)
    return vinfo.name
end

function value(phd::PHData, scen::ScenarioID, vid::VariableID)::Float64
    vinfo = retrieve_variable(phd.scenario_map[scen], vid)
    return vinfo.value
end

function value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    vid = VariableID(stage, idx)
    return value(phd, scen, vid)
end

function branch_value(phd::PHData, scen::ScenarioID, vid::VariableID)::Float64
    return phd.scenario_map[scen].branch_map[vid].value
end

branch_value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64 = branch_value(phd, scen, VariableID(stage, idx))

function leaf_value(phd::PHData, scen::ScenarioID, vid::VariableID)::Float64
    return phd.scenario_map[scen].leaf_map[vid].value
end

leaf_value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64 = leaf_value(phd, scen, VariableID(stage, idx))


function w_value(phd::PHData, scen::ScenarioID, vid::VariableID)::Float64
    return phd.scenario_map[scen].W[vid].value
end

function w_value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    vid = VariableID(stage, idx)
    return w_value(phd, scen, vid)
end

function xhat_value(phd::PHData, xhat_id::XhatID)::Float64
    return phd.Xhat[xhat_id].value
end

function xhat_value(phd::PHData, scen::ScenarioID, vid::VariableID)::Float64
    return xhat_value(phd, convert_to_xhat_id(phd, scen, vid))
end

function xhat_value(phd::PHData, scen::ScenarioID,
                    stage::StageID, idx::Index)::Float64
    return xhat_value(phd,
                      convert_to_xhat_id(phd, scen,
                                         VariableID(stage, idx))
                      )
end

function stringify(set::Set{K})::String where K
    str = ""
    for s in sort!(collect(set))
        str *= string(s) * ","
    end
    return rstrip(str, [',',' '])
end

function stringify(array::Vector{K})::String where K
    str = ""
    for s in sort(array)
        str *= string(s) * ","
    end
    return rstrip(str, [',',' '])
end

function retrieve_soln(phd::PHData)::DataFrames.DataFrame

    vars = Vector{String}()
    vals = Vector{Float64}()
    stages = Vector{STAGE_ID}()
    scens = Vector{String}()

    for xid in sort!(collect(keys(phd.Xhat)))

        scid, vid = convert_to_variable_id(phd, xid)

        push!(vars, name(phd, scid, vid))
        push!(vals, phd.Xhat[xid].value)
        push!(stages, _value(stage_id(phd, xid)))
        push!(scens, stringify(_value.(scenario_bundle(phd, xid))))

    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stages,
                                   scenarios=scens)

    return soln_df
end

function retrieve_aug_obj_value(phd::PHData)::Float64

    obj_value = 0.0

    for (scid, sinfo) in pairs(phd.scenario_map)
        subproblem = sinfo.subproblem
        obj = @spawnat(sinfo.proc, objective_value(fetch(subproblem)))
        obj_value += sinfo.prob * fetch(obj)
    end

    return obj_value
end

function retrieve_obj_value(phd::PHData)::Float64

    obj_value = 0.0

    for (scid, sinfo) in pairs(phd.scenario_map)

        subproblem = sinfo.subproblem
        obj = @spawnat(sinfo.proc, objective_value(fetch(subproblem)))
        obj_value += sinfo.prob * fetch(obj)

        # Remove PH terms
        for (vid, var) in pairs(sinfo.branch_map)
            x_val = var.value
            w_val = sinfo.W[vid].value
            xhat_val = xhat_value(phd, scid, vid)
            p = sinfo.prob
            r = phd.r

            obj_value -= p * (w_val * x_val + 0.5 * r * (x_val - xhat_val)^2)
        end
    end

    return obj_value
end

function two_stage_tree(n::Int;
                        pvect::Union{Nothing,Vector{R}}=nothing
                        )::ScenarioTree where R <: Real
    p = pvect == nothing ? [1.0/n for k in 1:n] : pvect

    st = ScenarioTree()
    for k in 1:n
        add_leaf(st, root(st), p[k])
    end
    return st
end

function visualize_tree(phd::PHData)
    # TODO: Implement this...
    @warn("Not yet implemented")
    return
end

function retrieve_no_hats(phd::PHData)::DataFrames.DataFrame
    vars = Vector{String}()
    vals = Vector{Float64}()
    stage = Vector{STAGE_ID}()
    scenario = Vector{SCENARIO_ID}()
    index = Vector{INDEX}()

    variable_map = Dict{UniqueVariableID, VariableInfo}()
    for (scid,sinfo) in phd.scenario_map
        for (vid,vinfo) in merge(sinfo.branch_map, sinfo.leaf_map)
            uvid = UniqueVariableID(scid, vid)
            variable_map[uvid] = vinfo
        end
    end

    for uvid in sort!(collect(keys(variable_map)))
        push!(vars, variable_map[uvid].name)
        push!(vals, variable_map[uvid].value)
        push!(stage, _value(uvid.stage))
        push!(scenario, _value(uvid.scenario))
        push!(index, _value(uvid.index))
    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stage,
                                   scenario=scenario, index=index)

    return soln_df
end

function retrieve_w(phd::PHData)::DataFrames.DataFrame
    vars = Vector{String}()
    vals = Vector{Float64}()
    stage = Vector{STAGE_ID}()
    scenario = Vector{SCENARIO_ID}()
    index = Vector{INDEX}()

    variable_map = Dict{UniqueVariableID, PHVariable}()
    for (scid,sinfo) in phd.scenario_map
        for (vid,w_var) in sinfo.W
            uvid = UniqueVariableID(scid, vid)
            variable_map[uvid] = w_var
        end
    end

    for uvid in sort!(collect(keys(variable_map)))

        vid = VariableID(uvid.stage, uvid.index)
        push!(vars, "W_" * phd.scenario_map[uvid.scenario].branch_map[vid].name)
        push!(vals, variable_map[uvid].value)
        push!(stage, _value(uvid.stage))
        push!(scenario, _value(uvid.scenario))
        push!(index, _value(uvid.index))

    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stage,
                                   scenario=scenario, index=index)

    return soln_df
end

function scid(n::SCENARIO_ID)::ScenarioID
    return ScenarioID(SCENARIO_ID(n))
end

function stid(n::STAGE_ID)::StageID
    return StageID(STAGE_ID(n))
end

function index(n::INDEX)::Index
    return Index(INDEX(n))
end
