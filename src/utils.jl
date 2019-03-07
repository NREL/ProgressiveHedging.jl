
# function get_value(model::M, name::String) where M <: JuMP.AbstractModel
#     return JuMP.value(JuMP.variable_by_name(model, name))
# end

# function get_fix_value(model::M, name::String) where M <: JuMP.AbstractModel
#     return JuMP.fix_value(JuMP.variable_by_name(model, name))
# end

# function ref(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)
#     return phd.variable_map[VariableID(scen, stage, idx)].ref
# end

function value(phd::PHData, vid::VariableID)
    return JuMP.value(phd.variable_map[vid].ref)
end

function value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)
    vid = VariableID(scen, stage, idx)
    return value(phd, vid)
end

function value(phd::PHData, xhat_id::XhatID)
    return phd.Xhat[xhat_id]
end

function value(phd::PHData, node::NodeID, idx::Index)
    xhatid = XhatID(node, idx)
    return value(phd, xhatid)
end

function stringify(set::Set{K}) where K
    str = ""
    for s in sort!(collect(set))
        str *= string(s) * ", "
    end
    return rstrip(str, [',',' '])
end

function stringify(array::Vector{K}) where K
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
        push!(vars, phd.name[var_id])
        push!(vals, phd.Xhat[xhat_id])
        push!(stages, _value(stage_id(xhat_id, phd)))
        push!(scens, stringify(_value.(scenario_bundle(xhat_id, phd))))
    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stages,
                                   scenarios=scens)

    return soln_df
end

function retrieve_obj_value(phd::PHData)
    # TODO: Implement this...
    @warn("Not yet implemented")
    return 0.0
end

function visualize_tree(phd::PHData)
    # TODO: Implement this...
    @warn("Not yet implemented")
    return
end

function retrieve_no_hats(phd::PHData)::DataFrames.DataFrame
    vars = Vector{JuMP.variable_type(first(phd.submodels)[2])}()
    vals = Vector{Float64}()
    stage = Vector{STAGE_ID}()
    scenario = Vector{SCENARIO_ID}()
    index = Vector{INDEX}()
    
    for vid in sort!(collect(keys(phd.variable_map)))
        vinfo = phd.variable_map[vid]
        push!(vars, vinfo.ref)
        push!(vals, JuMP.value(vinfo.ref))
        push!(stage, _value(vid.stage))
        push!(scenario, _value(vid.scenario))
        push!(index, _value(vid.index))
    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stage,
                                   scenario=scenario, index=index)

    return soln_df
end

function retrieve_w(phd::PHData)::DataFrames.DataFrame
    vars = Vector{JuMP.variable_type(first(phd.submodels)[2])}()
    vals = Vector{Float64}()
    stage = Vector{STAGE_ID}()
    scenario = Vector{SCENARIO_ID}()
    index = Vector{INDEX}()
    
    for vid in sort!(collect(keys(phd.W)))
        vinfo = phd.variable_map[vid]
        push!(vars, vinfo.ref)
        push!(vals, phd.W[vid])
        push!(stage, _value(vid.stage))
        push!(scenario, _value(vid.scenario))
        push!(index, _value(vid.index))
    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stage,
                                   scenario=scenario, index=index)

    return soln_df
end
