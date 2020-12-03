
function retrieve_values(phd::PHData, leaf_mode::Bool)::Nothing

    map_sym = leaf_mode ? :leaf_vars : :branch_vars

    val_dict = Dict{ScenarioID, Future}()
    for (scid,sinfo) in phd.scenario_map
        vars = collect(keys(getfield(sinfo, map_sym)))
        subprob = sinfo.subproblem
        val_dict[scid] = @spawnat(sinfo.proc, report_values(fetch(subprob), vars))
    end

    for (scid,fv) in pairs(val_dict)
        sinfo = phd.scenario_map[scid]
        var_values = fetch(fv)

        if typeof(var_values) == RemoteException
            # println(var_values.captured)
            throw(var_values)
        end

        for (vid, value) in pairs(var_values)
            vmap = getfield(sinfo, map_sym)
            vmap[vid].value = value
        end
    end

    return
end

function compute_and_save_xhat(phd::PHData)::Float64

    xhat_res = 0.0

    for (xhid, xhat_var) in pairs(phd.xhat)

        xhat = 0.0
        norm = 0.0

        for vid in variables(xhat_var)

            s = scenario(vid)
            p = phd.scenario_map[s].prob
            x = branch_value(phd, vid)

            xhat += p * x
            norm += p
        end

        xhat_new = xhat / norm
        xhat_old = value(xhat_var)

        xhat_var.value = xhat_new
        xhat_res += (xhat_new - xhat_old)^2
    end

    return xhat_res
end

function compute_and_save_w(phd::PHData)::Float64

    kxsq = 0.0

    for (xhid, xhat_var) in pairs(phd.xhat)

        xhat = value(xhat_var)

        exp = 0.0
        norm = 0.0

        for vid in variables(xhat_var)

            s = scenario(vid)
            p = phd.scenario_map[s].prob
            kx = branch_value(phd, vid) - xhat

            phd.scenario_map[s].w_vars[vid] += phd.r *kx

            kxsq += p * kx^2

            exp += p * w_value(phd, vid)
            norm += p
        end

        if abs(exp) > 1e-6
            @warn("Conditional expectation of " *
                  "W[$(scenario(vid)),$(stage(vid)),$(index(vid))] " *
                  "is non-zero: " * string(exp/norm))
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

    for (scid, sinfo) in pairs(phd.scenario_map)
        for (vid, vinfo) in pairs(sinfo.leaf_vars)
            xhid = convert_to_xhat_id(phd, vid)
            @assert(!haskey(phd.xhat, xhid))
            phd.xhat[xhid] = HatVariable(value(phd, vid), vid)
        end
    end

    return
end

# Some MOI interfaces do not support setting of start values
function set_start_values(phd::PHData)::Nothing

    @sync for (scid, sinfo) in pairs(phd.scenario_map)
        subproblem = sinfo.subproblem
        @spawnat(sinfo.proc, warm_start(fetch(subproblem)))
    end

    return

end

function update_si_xhat(phd::PHData)::Nothing

    for (xhid, xhat) in pairs(phd.xhat)
        for vid in variables(xhat)
            sinfo = phd.scenario_map[scenario(vid)]
            sinfo.xhat_vars[vid] = value(xhat)
        end
    end

    return
end

function fix_ph_variables(phd::PHData)::Nothing

    update_si_xhat(phd)

    @sync for sinfo in values(phd.scenario_map)

        (w_dict, xhat_dict) = create_ph_dicts(sinfo)
        subproblem = sinfo.subproblem

        @spawnat(sinfo.proc, update_ph_terms(fetch(subproblem), w_dict, xhat_dict))
    end

    return
end

function solve_subproblems(phd::PHData)::Nothing

    # Find subproblem solutions
    status = Dict{ScenarioID, Future}()
    @sync for (scen, sinfo) in pairs(phd.scenario_map)
        subproblem = sinfo.subproblem
        status[scen] = @spawnat(sinfo.proc, solve(fetch(subproblem)))
    end

    for (scen, sinfo) in pairs(phd.scenario_map)
        # MOI refers to the MathOptInterface package
        subproblem = sinfo.subproblem
        sts = fetch(status[scen])
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
               rtol::Float64,
               report::Int,
               save_res::Bool,
               warm_start::Bool,
               )::Tuple{Int,Float64}
    niter = 0
    report_flag = (report > 0)

    (xhat_res_sq, x_res_sq) = @timeit(ph_data.time_info, "Update PH Vars",
                                      update_ph_variables(ph_data))

    nsqrt = sqrt(length(ph_data.xhat))
    xmax = max(maximum(abs.(value.(values(ph_data.xhat)))), 1e-12)
    residual = sqrt(xhat_res_sq + x_res_sq) / nsqrt

    if report_flag
        @printf("Iter: %4d   AbsR: %12.6e   RelR: %12.6e   Xhat: %12.6e   X: %12.6e\n",
                niter, residual, residual/xmax,
                sqrt(xhat_res_sq)/nsqrt, sqrt(x_res_sq)/nsqrt
                )
        flush(stdout)
    end

    if save_res
        save_residual(ph_data, 0, residual)
    end
    
    while niter < max_iter && residual > atol && residual > rtol * xmax
        
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
        residual = sqrt(xhat_res_sq + x_res_sq) / nsqrt
        xmax = max(maximum(abs.(value.(values(ph_data.xhat)))), 1e-12)

        niter += 1

        if report_flag && niter % report == 0
            @printf("Iter: %4d   AbsR: %12.6e   RelR: %12.6e   Xhat: %12.6e   X: %12.6e\n",
                    niter, residual, residual/xmax,
                    sqrt(xhat_res_sq)/nsqrt, sqrt(x_res_sq)/nsqrt
                    )
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
