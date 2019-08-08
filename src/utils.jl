function _fetch_variable_value(phd::PHData, scid::ScenarioID,
                               vi::VariableInfo)::Float64
    ref = vi.ref
    return @fetchfrom(phd.scen_proc_map[scid], JuMP.value(fetch(ref)))
end

function value(phd::PHData, vid::VariableID)::Float64
    return _fetch_variable_value(phd, vid.scenario, phd.variable_map[vid])
end

function value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    vid = VariableID(scen, stage, idx)
    return _fetch_variable_value(phd, scen, phd.variable_map[vid])
end

function value(phd::PHData, xhat_id::XhatID)::Float64
    return phd.Xhat[xhat_id]
end

function value(phd::PHData, node::NodeID, idx::Index)::Float64
    xhatid = XhatID(node, idx)
    return value(phd, xhatid)
end

function w_value(phd::PHData, vid::VariableID)::Float64
    return phd.W[vid]
end

function xhat_value(phd::PHData, xhat_id::XhatID)::Float64
    return phd.Xhat[xhat_id]
end

function xhat_value(phd::PHData, vid::VariableID)::Float64
    return xhat_value(phd, convert_to_xhat_id(vid, phd))
end

function stringify(set::Set{K})::String where K
    str = ""
    for s in sort!(collect(set))
        str *= string(s) * ", "
    end
    return rstrip(str, [',',' '])
end

function stringify(array::Vector{K})::String where K
    str = ""
    for s in sort(array)
        str *= string(s) * ", "
    end
    return rstrip(str, [',',' '])
end

function retrieve_soln(phd::PHData)::DataFrames.DataFrame

    vars = Vector{String}()
    vals = Vector{Float64}()
    stages = Vector{STAGE_ID}()
    scens = Vector{String}()

    for xhat_id in sort!(collect(keys(phd.Xhat)))
        var_id = convert_to_variable_id(xhat_id, phd)
        push!(vars, phd.variable_map[var_id].name)
        push!(vals, phd.Xhat[xhat_id])
        push!(stages, _value(stage_id(xhat_id, phd)))
        push!(scens, stringify(_value.(scenario_bundle(xhat_id, phd))))
    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stages,
                                   scenarios=scens)

    return soln_df
end

function retrieve_obj_value(phd::PHData)::Float64

    # This is just the average of the various objective functions -- includes the
    # augmented terms
    obj_value = 0.0
    for (scid, model) in pairs(phd.submodels)
        obj = @spawnat(phd.scen_proc_map[scid], JuMP.objective_value(fetch(model)))
        obj_value += phd.probabilities[scid] * fetch(obj)
    end

    # Remove extra terms
    for (vid, var) in pairs(phd.variable_map)
        w_val = w_value(phd, vid)
        xhat_val = xhat_value(phd, vid)
        x_val = value(phd, vid)
        p = phd.probabilities[vid.scenario]

        obj_value -= p*(w_val * x_val + 0.5 * phd.r * (x_val - xhat_val)^2)
    end

    return obj_value
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
    
    for vid in sort!(collect(keys(phd.variable_map)))
        ref = phd.variable_map[vid].ref
        val = @spawnat(phd.scen_proc_map[vid.scenario],
                       JuMP.value(fetch(ref)))
        push!(vars, phd.variable_map[vid].name)
        push!(vals, fetch(val))
        push!(stage, _value(vid.stage))
        push!(scenario, _value(vid.scenario))
        push!(index, _value(vid.index))
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

    last = last_stage(phd.scenario_tree)
    
    for vid in sort!(collect(keys(phd.W)))

        if vid.stage == last
            continue
        end

        wref = phd.W_ref[vid]
        proc = phd.scen_proc_map[vid.scenario]
        push!(vars, "W_" * phd.variable_map[vid].name)

        push!(vals, phd.W[vid])
        push!(stage, _value(vid.stage))
        push!(scenario, _value(vid.scenario))
        push!(index, _value(vid.index))
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
