
function _report_values(var_dict::Dict{VariableID, VariableInfo}
                        )::Dict{VariableID, Float64}
    val_dict = Dict{VariableID, Float64}()
    for (vid, vinfo) in pairs(var_dict)
        val_dict[vid] = JuMP.value(fetch(vinfo.ref))
    end
    return val_dict
end

function retrieve_values(phd::PHData, leaf_mode::Bool)::Nothing

    map_sym = leaf_mode ? :leaf_map : :branch_map

    val_dict = Dict{ScenarioID, Future}()
    for (scid,sinfo) in phd.scenario_map
        vmap = getfield(sinfo, map_sym)
        val_dict[scid] = @spawnat(sinfo.proc, _report_values(vmap))
    end

    for (scid,fv) in pairs(val_dict)
        sinfo = phd.scenario_map[scid]
        var_values = fetch(fv)
        for (vid, value) in pairs(var_values)
            vmap = getfield(sinfo, map_sym)
            vmap[vid].value = value
        end
    end

    return
end

function compute_and_save_xhat(phd::PHData)::Float64

    xhat_res = 0.0

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)

        if is_leaf(node)
            continue
        end

        for i in node.variable_indices

            xhat = 0.0
            norm = 0.0
            
            for s in node.scenario_bundle
                
                p = phd.scenario_map[s].prob
                x = branch_value(phd, s, node.stage, i)

                xhat += p * x
                norm += p
                
            end

            xhat_id = XhatID(node_id,i)
            xhat_new = xhat / norm

            xhat_old = phd.Xhat[xhat_id].value
            phd.Xhat[xhat_id].value = xhat_new

            xhat_res += (xhat_new - xhat_old)^2
        end
    end

    return xhat_res
end

function compute_and_save_w(phd::PHData)::Float64

    kxsq = 0.0

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)

        if is_leaf(node)
            continue
        end

        for i in node.variable_indices

            xhat = phd.Xhat[XhatID(node_id,i)].value
            
            exp = 0.0
            norm = 0.0

            for s in node.scenario_bundle
                p = phd.scenario_map[s].prob

                var_id = VariableID(node.stage, i)
                kx = branch_value(phd, s, var_id) - xhat
                phd.scenario_map[s].W[var_id].value += phd.r * kx

                kxsq += p * kx^2

                exp += p * phd.scenario_map[s].W[var_id].value
                norm += p
            end

            if abs(exp) > 1e-6
                @warn("Conditional expectation of " *
                      "W[$(node.scenario_bundle),$(node.stage),$i] " *
                      "is non-zero: " * string(exp/norm))
            end
        end
    end

    return kxsq
end

function update_ph_variables(phd::PHData)::Tuple{Float64,Float64}
    retrieve_values(phd, false)
    xhat_residual = compute_and_save_xhat(phd)
    x_residual = compute_and_save_w(phd)
    return (xhat_residual, x_residual)
end

function update_ph_leaf_variables(phd::PHData)::Nothing
    retrieve_values(phd, true)

    for (xid, xhat) in pairs(phd.Xhat)
        if is_leaf(phd.scenario_tree, xid.node)
            @assert(length(scenario_bundle(phd, xid)) == 1)
            (scid, vid) = convert_to_variable_id(phd, xid)
            xhat.value = phd.scenario_map[scid].leaf_map[vid].value
        end
    end

    return
end

# Some MOI interfaces do not support setting of start values
function _set_start_values(model::JuMP.Model)::Nothing
    for var in JuMP.all_variables(model)
        if !JuMP.is_fixed(var)
            JuMP.set_start_value(var, JuMP.value(var))
        end
    end
    return
end

function set_start_values(phd::PHData)::Nothing

    @sync for (scid, sinfo) in pairs(phd.scenario_map)
        model = sinfo.model
        @spawnat(sinfo.proc, _set_start_values(fetch(model)))
    end

    return

end

function _fix_values(ph_vars::Vector{PHVariable})::Nothing

    for phv in ph_vars
        JuMP.fix(fetch(phv.ref), phv.value, force=true)
    end

    return
end

function update_si_xhat(phd::PHData)::Nothing
    for (scid, sinfo) in pairs(phd.scenario_map)
        for (xhat_id, x_var) in pairs(sinfo.Xhat)
            x_var.value = phd.Xhat[xhat_id].value
        end
    end
    return
end

function fix_ph_variables(phd::PHData)::Nothing

    update_si_xhat(phd)

    @sync for (scid, sinfo) in pairs(phd.scenario_map)
        w_array = collect(values(sinfo.W))
        xhat_array = collect(values(sinfo.Xhat))

        @spawnat(sinfo.proc, _fix_values(w_array))
        @spawnat(sinfo.proc, _fix_values(xhat_array))
    end

    return
end

function solve_subproblems(phd::PHData)::Nothing

    # Find subproblem solutions--in parallel if we have the workers for it.
    # @sync will wait for all processes to complete
    @sync for (scen, sinfo) in pairs(phd.scenario_map)
        model = sinfo.model
        @spawnat(sinfo.proc, JuMP.optimize!(fetch(model)))
    end

    for (scen, sinfo) in pairs(phd.scenario_map)
        # MOI refers to the MathOptInterface package. Apparently this is made
        # accessible by JuMP since it is not imported here
        model = sinfo.model
        sts = fetch(@spawnat(sinfo.proc, JuMP.termination_status(fetch(model))))
        if sts != MOI.OPTIMAL && sts != MOI.LOCALLY_SOLVED &&
            sts != MOI.ALMOST_LOCALLY_SOLVED
            @error("Scenario $scen subproblem returned $sts.")
        end
    end

    return
end

function hedge(ph_data::PHData,
               max_iter::Int,
               atol::Float64,
               report::Int,
               save_res::Bool,
               warm_start::Bool,
               )::Tuple{Int,Float64}
    niter = 0
    report_flag = (report > 0)

    (xhat_res_sq, x_res_sq) = @timeit(ph_data.time_info, "Update PH Vars",
                                      update_ph_variables(ph_data))

    nsqrt = sqrt(length(ph_data.Xhat))
    residual = sqrt(xhat_res_sq + x_res_sq) / nsqrt

    if report_flag
        @printf("Iter: %4d    Res: %12.6e    Xhat: %12.6e    X: %12.6e\n",
                niter, residual, sqrt(xhat_res_sq)/nsqrt, sqrt(x_res_sq)/nsqrt)
        flush(stdout)
    end

    if save_res
        save_residual(ph_data, 0, residual)
    end
    
    while niter < max_iter && residual > atol
        
        # Set initial values, fix cross model values (W and Xhat) and
        # solve the subproblems

        # Setting start values causes issues with some solvers
        if warm_start
            @timeit(ph_data.time_info, "Set start values",
                    set_start_values(ph_data))
        end
        @timeit(ph_data.time_info, "Fix PH variables",
                fix_ph_variables(ph_data))

        @timeit(ph_data.time_info, "Solve subproblems",
                solve_subproblems(ph_data))

        # Update xhat and w
        (xhat_res_sq, x_res_sq) = @timeit(ph_data.time_info, "Update PH Vars",
                                          update_ph_variables(ph_data))

        # Update stopping criteria -- xhat_res_sq measures the movement of
        # xhat values from k^th iteration to the (k+1)^th iteration while
        # x_res_sq measures the disagreement between the x variables and
        # its corresponding xhat variable (so lack of consensus amongst the
        # subproblems or violation of the nonanticipativity constraint)
        residual= sqrt(xhat_res_sq + x_res_sq) / nsqrt
        
        niter += 1

        if report_flag && niter % report == 0
            @printf("Iter: %4d    Res: %12.6e    Xhat: %12.6e    X: %12.6e\n",
                    niter, residual, sqrt(xhat_res_sq)/nsqrt, sqrt(x_res_sq)/nsqrt)
            flush(stdout)
        end

        if save_res
            save_residual(ph_data, niter, residual)
        end

    end

    @timeit(ph_data.time_info, "Update PH leaf variables",
            update_ph_leaf_variables(ph_data))

    if niter >= max_iter && residual > atol
        @warn("Performed $niter iterations without convergence. " *
              "Consider increasing max_iter from $max_iter.")
    end

    return (niter, residual)
end
