function name(phd::PHData, vid::VariableID)::String
    if !haskey(phd.variable_data, vid)
        error("No name available for variable id $vid")
    end
    return phd.variable_data[vid].name
end

function value(phd::PHData, vid::VariableID)::Float64
    return retrieve_variable_value(phd.scenario_map[scenario(vid)], vid)
end

function value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    vid = VariableID(scen, stage, idx)
    return value(phd, vid)
end

function branch_value(phd::PHData, vid::VariableID)::Float64
    return phd.scenario_map[scenario(vid)].branch_vars[vid]
end

function branch_value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    return branch_value(phd, VariableID(scen, stage, idx))
end

function leaf_value(phd::PHData, vid::VariableID)::Float64
    return phd.scenario_map[scenario(vid)].leaf_vars[vid]
end

function leaf_value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    return leaf_value(phd, VariableID(scen, stage, idx))
end

function w_value(phd::PHData, vid::VariableID)::Float64
    return phd.scenario_map[scenario(vid)].w_vars[vid]
end

function w_value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    return w_value(phd, VariableID(scen, stage, idx))
end

function xhat_value(phd::PHData, xhat_id::XhatID)::Float64
    return value(phd.xhat[xhat_id])
end

function xhat_value(phd::PHData, vid::VariableID)::Float64
    return xhat_value(phd, convert_to_xhat_id(phd, vid))
end

function xhat_value(phd::PHData, scen::ScenarioID, stage::StageID, idx::Index)::Float64
    return xhat_value(phd, VariableID(scen, stage, idx))
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

    for xid in sort!(collect(keys(phd.xhat)))

        vid = first(convert_to_variable_ids(phd, xid))

        push!(vars, name(phd, vid))
        push!(vals, xhat_value(phd, xid))
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
        obj_value += sinfo.prob * objective_value(sinfo)
    end

    return obj_value
end

function retrieve_obj_value(phd::PHData)::Float64

    obj_value = 0.0

    for (scid, sinfo) in pairs(phd.scenario_map)

        obj_s = objective_value(sinfo)

        # Remove PH terms
        for (vid, x_val) in pairs(sinfo.branch_vars)
            w_val = sinfo.w_vars[vid]
            xhat_val = xhat_value(phd, vid)
            r = get_penalty_value(phd.r, convert_to_xhat_id(phd, vid))
            obj_s -= w_val * x_val + 0.5 * r * (x_val - xhat_val)^2
        end

        obj_value += sinfo.prob * obj_s

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

    variable_map = Dict{VariableID, Float64}()
    for (scid,sinfo) in phd.scenario_map
        merge!(variable_map, sinfo.branch_vars, sinfo.leaf_vars)
    end

    for vid in sort!(collect(keys(variable_map)))
        push!(vars, name(phd, vid))
        push!(vals, variable_map[vid])
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

    variable_map = Dict{VariableID, Float64}()
    for (scid,sinfo) in phd.scenario_map
        merge!(variable_map, sinfo.w_vars)
    end

    for vid in sort!(collect(keys(variable_map)))

        push!(vars, "W_" * name(phd, vid))
        push!(vals, variable_map[vid])
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

function retrieve_xhat_history(phd::PHData)::DataFrames.DataFrame

    xhat_df = nothing
    iterates = phd.iterate_history.iterates

    for iter in sort!(collect(keys(iterates)))

        data = Dict{String,Any}("iteration" => iter)

        for xhid in sort!(collect(keys(phd.xhat)))
            if !is_leaf(phd, xhid)
                vname = name(phd, xhid) * "_" * stringify(_value.(scenario_bundle(phd, xhid)))
                data[vname] = iterates[iter].xhat[xhid]
            end
        end

        if xhat_df == nothing
            xhat_df = DataFrames.DataFrame(data)
        else
            push!(xhat_df, data)
        end
    end

    if xhat_df == nothing
        xhat_df = DataFrames.DataFrame()
    end

    return xhat_df
end

function retrieve_no_hat_history(phd::PHData)::DataFrames.DataFrame

    x_df = nothing
    iterates = phd.iterate_history.iterates

    for iter in sort!(collect(keys(iterates)))

        current_iterate = iterates[iter]
        data = Dict{String,Any}("iteration" => iter)

        for vid in sort!(collect(keys(current_iterate.x)))
            vname = name(phd, vid) * "_$(_value(scenario(vid)))"
            data[vname] = current_iterate.x[vid]
        end

        if x_df == nothing
            x_df = DataFrames.DataFrame(data)
        else
            push!(x_df, data)
        end
    end

    if x_df == nothing
        x_df = DataFrames.DataFrame()
    end

    return x_df
end

function retrieve_w_history(phd::PHData)::DataFrames.DataFrame

    w_df = nothing
    iterates = phd.iterate_history.iterates

    for iter in sort!(collect(keys(iterates)))

        current_iterate = iterates[iter]
        data = Dict{String,Any}("iteration" => iter)

        for vid in sort!(collect(keys(current_iterate.w)))
            vname = "W_" * name(phd, vid) * "_$(_value(scenario(vid)))"
            data[vname] = current_iterate.w[vid]
        end

        if w_df == nothing
            w_df = DataFrames.DataFrame(data)
        else
            push!(w_df, data)
        end
    end

    if w_df == nothing
        w_df = DataFrames.DataFrame()
    end

    return w_df
end
