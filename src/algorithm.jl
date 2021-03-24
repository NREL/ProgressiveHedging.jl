
function _copy_values(target::Dict{VariableID,Float64},
                      source::Dict{VariableID,Float64}
                      )::Nothing

    for (vid, value) in pairs(source)
        target[vid] = value
    end

    return
end

function _process_reports(phd::PHData,
                          winf::WorkerInf,
                          report_type::Union{Type{ReportBranch},Type{ReportLeaf}},
                          )::Nothing

    waiting_on = copy(scenarios(phd))

    while !isempty(waiting_on)

        msg = _retrieve_message_type(winf, report_type)
        _verify_report(msg)
        _update_values(phd, msg)

        delete!(waiting_on, msg.scen)
    end

    return
end

function _save_iterate(phd::PHData,
                       iter::Int,
                       )::Nothing

    xhd = Dict{XhatID,Float64}()
    xd = Dict{VariableID,Float64}()
    wd = Dict{VariableID,Float64}()

    for (xhid, xhat) in pairs(phd.xhat)
        xhd[xhid] = value(xhat)
        for vid in variables(xhat)
            xd[vid] = branch_value(phd, vid)
            wd[vid] = w_value(phd, vid)
        end
    end

    # for sinfo in values(phd.scenario_map)
    #     for (vid, x) in pairs(sinfo.leaf_vars)
    #         xd[vid] = x
    #     end
    # end

    _save_iterate(phd.iterate_history,
                  iter,
                  PHIterate(xhd, xd, wd)
                  )

    return
end

function _save_residual(phd::PHData,
                        iter::Int,
                        xhat_sq::Float64,
                        x_sq::Float64,
                        absr::Float64,
                        relr::Float64,
                        )::Nothing
    _save_residual(phd.residual_history, iter, PHResidual(absr, relr, xhat_sq, x_sq))
    return
end

function _send_solve_commands(phd::PHData,
                              winf::WorkerInf,
                              )::Nothing
    @sync for (scen, sinfo) in pairs(phd.scenario_map)
        (w_dict, xhat_dict) = create_ph_dicts(sinfo)
        @async _send_message(winf, sinfo.pid, Solve(scen, w_dict, xhat_dict))
    end

    return
end

function _update_si_xhat(phd::PHData)::Nothing

    for (xhid, xhat) in pairs(phd.xhat)
        for vid in variables(xhat)
            sinfo = phd.scenario_map[scenario(vid)]
            sinfo.xhat_vars[vid] = value(xhat)
        end
    end

    return
end

function _update_values(phd::PHData,
                        msg::ReportBranch
                        )::Nothing

    sinfo = phd.scenario_map[msg.scen]

    pd = sinfo.problem_data
    pd.obj = msg.obj
    pd.sts = msg.sts
    pd.time = msg.time

    _copy_values(sinfo.branch_vars, msg.vals)

    return
end

function _update_values(phd::PHData,
                        msg::ReportLeaf
                        )::Nothing
    return _copy_values(phd.scenario_map[msg.scen].leaf_vars, msg.vals)
end

function _verify_report(msg::ReportBranch)::Nothing
    if (msg.sts != MOI.OPTIMAL &&
        msg.sts != MOI.LOCALLY_SOLVED &&
        msg.sts != MOI.ALMOST_LOCALLY_SOLVED)
        # TODO: Create user adjustable/definable behavior for when this happens
        @error("Scenario $(msg.scen) subproblem returned $(msg.sts).")
    end
    return
end

function _verify_report(msg::ReportLeaf)::Nothing
    # Intentional no-op
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
            r = get_penalty_value(phd.r, xhid)

            phd.scenario_map[s].w_vars[vid] += r * kx

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

function update_ph_variables(phd::PHData)::NTuple{2,Float64}

    xhat_sq = compute_and_save_xhat(phd)
    x_sq = compute_and_save_w(phd)

    return (xhat_sq, x_sq)
end

function solve_subproblems(phd::PHData,
                           winf::WorkerInf,
                           )::Nothing

    # Copy hat values to scenario base structure for easy dispersal
    @timeit(phd.time_info,
            "Other",
            _update_si_xhat(phd))

    # Send solve command to workers
    @timeit(phd.time_info,
            "Issuing solve commands",
            _send_solve_commands(phd, winf))

    # Wait for and process replies
    @timeit(phd.time_info,
            "Collecting results",
            _process_reports(phd, winf, ReportBranch))

    return
end

function finish(phd::PHData,
                winf::WorkerInf,
                )::Nothing

    # Send shutdown command to workers
    _shutdown(winf)

    # Wait for and process replies
    _process_reports(phd, winf, ReportLeaf)

    # Create hat variables for all leaf variables so
    # that `retrieve_soln` picks up the values
    for (scid, sinfo) in pairs(phd.scenario_map)
        for (vid, vinfo) in pairs(sinfo.leaf_vars)
            xhid = convert_to_xhat_id(phd, vid)
            @assert(!haskey(phd.xhat, xhid))
            # TODO: Correctly assign whether leaf variables are integers. For now,
            # just say they aren't because it doesn't really matter.
            phd.xhat[xhid] = HatVariable(value(phd, vid), vid, false)
        end
    end

    # Wait for workers to exit cleanly
    _wait_for_shutdown(winf)

    return
end

function hedge(ph_data::PHData,
               worker_inf::WorkerInf,
               max_iter::Int,
               atol::Float64,
               rtol::Float64,
               report::Int,
               save_iter::Int,
               save_res::Int,
               )::Tuple{Int,Float64,Float64}

    niter = 0
    report_flag = (report > 0)
    save_iter_flag = (save_iter > 0)
    save_res_flag = (save_res > 0)

    cr = ph_data.residual_history.residuals[-1]
    delete!(ph_data.residual_history.residuals, -1)
    xhat_res_sq = cr.xhat_sq
    x_res_sq = cr.x_sq

    nsqrt = sqrt(length(ph_data.xhat))
    xmax = max(maximum(abs.(value.(values(ph_data.xhat)))), 1e-12)
    residual = sqrt(xhat_res_sq + x_res_sq) / nsqrt

    if report_flag
        @printf("Iter: %4d   AbsR: %12.6e   RelR: %12.6e   Xhat: %12.6e   X: %12.6e\n",
                niter, residual, residual / xmax,
                sqrt(xhat_res_sq)/nsqrt, sqrt(x_res_sq)/nsqrt
                )
        flush(stdout)
    end

    if save_iter_flag
        _save_iterate(ph_data, 0)
    end

    if save_res_flag
        _save_residual(ph_data, 0, xhat_res_sq, x_res_sq, residual, residual/xmax)
    end
    
    while niter < max_iter && residual > atol && residual > rtol * xmax

        # Solve subproblems
        @timeit(ph_data.time_info,
                "Solve subproblems",
                solve_subproblems(ph_data, worker_inf)
                )

        # Update xhat and w
        (xhat_res_sq, x_res_sq) = @timeit(ph_data.time_info,
                                          "Update PH Vars",
                                          update_ph_variables(ph_data)
                                          )

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
                    niter, residual, residual / xmax,
                    sqrt(xhat_res_sq)/nsqrt, sqrt(x_res_sq)/nsqrt
                    )
            flush(stdout)
        end

        if save_iter_flag && niter % save_iter == 0
            _save_iterate(ph_data, niter)
        end

        if save_res_flag && niter % save_res == 0
            _save_residual(ph_data,
                           niter,
                           xhat_res_sq,
                           x_res_sq,
                           residual,
                           residual/xmax
                           )
        end

    end

    @timeit(ph_data.time_info,
            "Finishing",
            finish(ph_data, worker_inf)
            )

    if niter >= max_iter && residual > atol && residual > rtol * xmax
        @warn("Performed $niter iterations without convergence. " *
              "Consider increasing max_iter from $max_iter.")
    end

    return (niter, residual, residual/xmax)
end
