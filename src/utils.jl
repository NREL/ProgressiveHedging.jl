
## Helper Functions ##

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

## Generic Utility Functions ##

function _two_stage_tree(n::Int, p::Vector{R})::ScenarioTree where R <: Real
    st = ScenarioTree()
    for s in 1:n
        add_leaf(st, root(st), p[s])
    end
    return st
end

"""
    two_stage_tree(n::Int)::ScenarioTree
    two_stage_tree(p::Vector{R})::ScenarioTree where R <: Real

Construct and return a two-stage scenario tree with `n` scenarios with equal probability or a two-stage scenario tree with `length(p)` scenarios where probability of scenario s is `p[s+1]`.
"""
function two_stage_tree(n::Int)::ScenarioTree
    return _two_stage_tree(n, [1.0/n for k in 1:n])
end

function two_stage_tree(p::Vector{R})::ScenarioTree where R <: Real
    if !isapprox(sum(p), 1.0, atol=1e-8)
        @warn("Given probability vector has total probability $(sum(p)). Normalizing to 1.")
        p /= sum(p)
    end
    return _two_stage_tree(length(p), p)
end

function visualize_tree(phd::PHData)
    # TODO: Implement this...
    @warn("Not yet implemented")
    return
end

## Complex PHData Interaction Functions ##

# NOTE: These functions are almost all post-processing functions

"""
    lower_bounds(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with the computed and saved lower bounds. See the `lower_bound` keyword argument on [`solve`](@ref).
"""
function lower_bounds(phd::PHData)::DataFrames.DataFrame

    lb_df = nothing
    lower_bounds = phd.history.lower_bounds

    for iter in sort!(collect(keys(lower_bounds)))
        lb = lower_bounds[iter]
        data = Dict{String,Any}("iteration" => iter,
                                "bound" => lb.lower_bound,
                                "absolute gap" => lb.gap,
                                "relative gap" => lb.rel_gap,
                                )

        if isnothing(lb_df)
            lb_df = DataFrames.DataFrame(data)
        else
            push!(lb_df, data)
        end
    end

    if isnothing(lb_df)
        lb_df = DataFrames.DataFrame()
    end

    return lb_df
end

"""
    residuals(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with absolute and relative residuals along with the components. See the `save_residuals` keyword argument on [`solve`](@ref).
"""
function residuals(phd::PHData)::DataFrames.DataFrame

    res_df = nothing
    residuals = phd.history.residuals

    for iter in sort!(collect(keys(residuals)))
        res = residuals[iter]
        data = Dict{String,Any}("iteration" => iter,
                                "absolute" => res.abs_res,
                                "relative" => res.rel_res,
                                "xhat_sq" => res.xhat_sq,
                                "x_sq" => res.x_sq
                                )

        if isnothing(res_df)
            res_df = DataFrames.DataFrame(data)
        else
            push!(res_df, data)
        end
    end

    if isnothing(res_df)
        res_df = DataFrames.DataFrame()
    end

    return res_df
end

"""
    retrieve_soln(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with the solution values of all consensus and leaf variables.
"""
function retrieve_soln(phd::PHData)::DataFrames.DataFrame

    vars = Vector{String}()
    vals = Vector{Float64}()
    stages = Vector{STAGE_ID}()
    scens = Vector{String}()

    for xid in sort!(collect(keys(phd.xhat)))

        vid = first(convert_to_variable_ids(phd, xid))

        push!(vars, name(phd, vid))
        push!(vals, xhat_value(phd, xid))
        push!(stages, value(stage_id(phd, xid)))
        push!(scens, stringify(value.(scenario_bundle(phd, xid))))

    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stages,
                                   scenarios=scens)

    return soln_df
end

"""
    retrieve_aug_obj_value(phd::PHData)::Float64

Return the current objective value including Lagrange and proximal PH terms of the stochastic program.
"""
function retrieve_aug_obj_value(phd::PHData)::Float64

    obj_value = 0.0

    for (scid, sinfo) in pairs(phd.scenario_map)
        obj_value += sinfo.prob * objective_value(sinfo)
    end

    return obj_value
end

"""
    retrieve_obj_value(phd::PHData)::Float64

Return the current objective value without Lagrange and proximal PH terms.
"""
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

"""
    retrieve_no_hats(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with the final nonconsensus variable values.
"""
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
        push!(stage, value(vid.stage))
        push!(scenario, value(vid.scenario))
        push!(index, value(vid.index))
    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stage,
                                   scenario=scenario, index=index)

    return soln_df
end

"""
    retrieve_w(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with the final anticipativity constraint Lagrange multiplier values.
"""
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
        push!(stage, value(vid.stage))
        push!(scenario, value(vid.scenario))
        push!(index, value(vid.index))

    end

    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stage,
                                   scenario=scenario, index=index)

    return soln_df
end

"""
    retrieve_xhat_history(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with the saved consensus variable values. See the `save_iterates` keyword argument on [`solve`](@ref).
"""
function retrieve_xhat_history(phd::PHData)::DataFrames.DataFrame

    xhat_df = nothing
    iterates = phd.history.iterates

    for iter in sort!(collect(keys(iterates)))

        data = Dict{String,Any}("iteration" => iter)

        for xhid in sort!(collect(keys(phd.xhat)))
            if !is_leaf(phd, xhid)
                vname = name(phd, xhid) * "_" * stringify(value.(scenario_bundle(phd, xhid)))
                data[vname] = iterates[iter].xhat[xhid]
            end
        end

        if isnothing(xhat_df)
            xhat_df = DataFrames.DataFrame(data)
        else
            push!(xhat_df, data)
        end
    end

    if isnothing(xhat_df)
        xhat_df = DataFrames.DataFrame()
    end

    return xhat_df
end

"""
    retrieve_no_hat_history(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with the saved nonconsensus variable values. See the `save_iterates` keyword argument on [`solve`](@ref).
"""
function retrieve_no_hat_history(phd::PHData)::DataFrames.DataFrame

    x_df = nothing
    iterates = phd.history.iterates

    for iter in sort!(collect(keys(iterates)))

        current_iterate = iterates[iter]
        data = Dict{String,Any}("iteration" => iter)

        for vid in sort!(collect(keys(current_iterate.x)))
            vname = name(phd, vid) * "_$(value(scenario(vid)))"
            data[vname] = current_iterate.x[vid]
        end

        if isnothing(x_df)
            x_df = DataFrames.DataFrame(data)
        else
            push!(x_df, data)
        end
    end

    if isnothing(x_df)
        x_df = DataFrames.DataFrame()
    end

    return x_df
end

"""
    retrieve_w_history(phd::PHData)::DataFrames.DataFrame

Return a `DataFrame` with the saved PH Lagrange variable values. See the `save_iterates` keyword argument on [`solve`](@ref).
"""
function retrieve_w_history(phd::PHData)::DataFrames.DataFrame

    w_df = nothing
    iterates = phd.history.iterates

    for iter in sort!(collect(keys(iterates)))

        current_iterate = iterates[iter]
        data = Dict{String,Any}("iteration" => iter)

        for vid in sort!(collect(keys(current_iterate.w)))
            vname = "W_" * name(phd, vid) * "_$(value(scenario(vid)))"
            data[vname] = current_iterate.w[vid]
        end

        if isnothing(w_df)
            w_df = DataFrames.DataFrame(data)
        else
            push!(w_df, data)
        end
    end

    if isnothing(w_df)
        w_df = DataFrames.DataFrame()
    end

    return w_df
end
