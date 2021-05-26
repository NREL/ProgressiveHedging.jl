
function _copy_values(target::Dict{VariableID,Float64},
                      source::Dict{VariableID,Float64}
                      )::Nothing

    for (vid, value) in pairs(source)
        target[vid] = value
    end

    return

end

function _execute_callbacks(phd::PHData, winf::WorkerInf, niter::Int)::Bool

    running = true

    for cb in phd.callbacks
        running &= cb.h(cb.ext, phd, winf, niter)
    end

    return running

end

function _process_reports(phd::PHData,
                          winf::WorkerInf,
                          report_type::Type{R}
                          )::Nothing where R <: Report

    waiting_on = copy(scenarios(phd))

    while !isempty(waiting_on)

        msg = _retrieve_message_type(winf, report_type)
        _verify_report(msg)
        _update_values(phd, msg)

        delete!(waiting_on, msg.scen)
    end

    return

end

function _report(niter::Int,
                 nsqrt::Float64,
                 residual::Float64,
                 xmax::Float64,
                 xhat_sq::Float64,
                 x_sq::Float64
                 )::Nothing

    @printf("Iter: %4d   AbsR: %12.6e   RelR: %12.6e   Xhat: %12.6e   X: %12.6e\n",
            niter, residual, residual / xmax,
            sqrt(xhat_sq)/nsqrt, sqrt(x_sq)/nsqrt
            )
    flush(stdout)

    return

end

function _report_lower_bound(niter::Int, bound::Float64, gap::Float64)::Nothing

    @printf("Iter: %4d   Bound: %12.4e   Abs Gap: %12.4e   Rel Gap: %8.4g\n",
            niter, bound, gap, gap/bound
            )
    flush(stdout)

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

    _save_iterate(phd.history,
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
    _save_residual(phd.history, iter, PHResidual(absr, relr, xhat_sq, x_sq))
    return
end

function _send_solve_commands(phd::PHData,
                              winf::WorkerInf,
                              niter::Int
                              )::Nothing

    @sync for (scen, sinfo) in pairs(phd.scenario_map)

        (w_dict, xhat_dict) = create_ph_dicts(sinfo)

        @async _send_message(winf,
                             sinfo.pid,
                             Solve(scen,
                                   w_dict,
                                   xhat_dict,
                                   niter
                                   )
                             )

    end

    return

end

function _send_lb_solve_commands(phd::PHData,
                                 winf::WorkerInf,
                                 )::Nothing

    @sync for (scen, sinfo) in pairs(phd.scenario_map)
        (w_dict, xhat_dict) = create_ph_dicts(sinfo)
        @async _send_message(winf, sinfo.pid, SolveLowerBound(scen, w_dict))
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
    _copy_values(phd.scenario_map[msg.scen].leaf_vars, msg.vals)
    return
end

function _update_values(phd::PHData,
                        msg::ReportLowerBound
                        )::Nothing

    pd = phd.scenario_map[msg.scen].problem_data

    pd.lb_obj = msg.obj
    pd.lb_sts = msg.sts
    pd.lb_time = msg.time

    return

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

function _verify_report(msg::ReportLowerBound)::Nothing

    if (msg.sts != MOI.OPTIMAL &&
        msg.sts != MOI.LOCALLY_SOLVED &&
        msg.sts != MOI.ALMOST_LOCALLY_SOLVED)
        # TODO: Create user adjustable/definable behavior for when this happens
        @error("Scenario $(msg.scen) lower-bound subproblem returned $(msg.sts).")
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
            r = get_penalty_value(phd.r, xhid)

            phd.scenario_map[s].w_vars[vid] += r * kx

            kxsq += p * kx^2

            exp += p * w_value(phd, vid)
            norm += p

        end

        if abs(exp) > 1e-6
            vname = name(phd, xhid)
            @warn("Conditional expectation of " *
                  "W[$(vname)] occurring in stage " * stage_id(phd, xhid) *
                  " for scenarios " * stringify(scenario_bundle(phd, xhid)) *
                  " is non-zero: " * string(exp/norm))
        end
    end

    return kxsq

end

function compute_gap(phd::PHData)::NTuple{2,Float64}

    gap = 0.0
    lb = 0.0

    for s in scenarios(phd)

        sinfo = phd.scenario_map[s]
        pd = sinfo.problem_data
        p = sinfo.prob

        gap += p * abs(pd.obj - pd.lb_obj)
        lb += p * pd.lb_obj

    end

    return (lb, gap)

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

function update_gap(phd::PHData, winf::WorkerInf, niter::Int)::NTuple{2,Float64}

    @timeit(phd.time_info,
            "Issuing lower bound solve commands",
            _send_lb_solve_commands(phd, winf)
            )

    @timeit(phd.time_info,
            "Collecting lower bound results",
            _process_reports(phd, winf, ReportLowerBound)
            )

    (lb, gap) = @timeit(phd.time_info,
                        "Computing gap",
                        compute_gap(phd)
                        )

    _save_lower_bound(phd.history,
                      niter,
                      PHLowerBound(lb, gap, gap/lb)
                      )

    return (lb, gap)

end

function update_ph_variables(phd::PHData)::NTuple{2,Float64}

    xhat_sq = compute_and_save_xhat(phd)
    x_sq = compute_and_save_w(phd)

    return (xhat_sq, x_sq)

end

function solve_subproblems(phd::PHData,
                           winf::WorkerInf,
                           niter::Int,
                           )::Nothing

    # Copy hat values to scenario base structure for easy dispersal
    @timeit(phd.time_info,
            "Other",
            _update_si_xhat(phd))

    # Send solve command to workers
    @timeit(phd.time_info,
            "Issuing solve commands",
            _send_solve_commands(phd, winf, niter))

    # Wait for and process replies
    @timeit(phd.time_info,
            "Collecting results",
            _process_reports(phd, winf, ReportBranch))

    return

end

function hedge(ph_data::PHData,
               worker_inf::WorkerInf,
               max_iter::Int,
               atol::Float64,
               rtol::Float64,
               gap_tol::Float64,
               report::Int,
               save_iter::Int,
               save_res::Int,
               lower_bound::Int,
               )::Tuple{Int,Float64,Float64}

    niter = 0
    report_flag = (report > 0)
    save_iter_flag = (save_iter > 0)
    save_res_flag = (save_res > 0)
    lb_flag = (lower_bound > 0)

    cr = ph_data.history.residuals[-1]
    delete!(ph_data.history.residuals, -1)
    xhat_res_sq = cr.xhat_sq
    x_res_sq = cr.x_sq

    nsqrt = max(sqrt(length(ph_data.xhat)), 1.0)
    xmax = (length(ph_data.xhat) > 0
            ? max(maximum(abs.(value.(values(ph_data.xhat)))), 1e-12)
            : 1.0)
    residual = sqrt(xhat_res_sq + x_res_sq) / nsqrt

    user_continue = @timeit(ph_data.time_info,
                            "User Callbacks",
                            _execute_callbacks(ph_data, worker_inf, niter)
                            )

    if report_flag
        _report(niter, nsqrt, residual, xmax, xhat_res_sq, x_res_sq)
    end

    if lb_flag
        (lb, gap) = @timeit(ph_data.time_info,
                            "Update Gap",
                            update_gap(ph_data, worker_inf, niter)
                            )
        if report_flag
            _report_lower_bound(niter, lb, gap)
        end
    end

    if save_iter_flag
        _save_iterate(ph_data, 0)
    end

    if save_res_flag
        _save_residual(ph_data, 0, xhat_res_sq, x_res_sq, residual, residual/xmax)
    end

    running = (user_continue
               && niter < max_iter
               && residual > atol
               && residual > rtol * xmax
               && (lb_flag ? gap > lb * gap_tol : true)
               )
    
    while running

        niter += 1

        # Solve subproblems
        @timeit(ph_data.time_info,
                "Solve subproblems",
                solve_subproblems(ph_data, worker_inf, niter)
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

        user_continue = @timeit(ph_data.time_info,
                                "User Callbacks",
                                _execute_callbacks(ph_data, worker_inf, niter)
                                )

        running = (user_continue
                   && niter < max_iter
                   && residual > atol
                   && residual > rtol * xmax
                   && (lb_flag ? gap > lb * gap_tol : true)
                   )

        if report_flag && (niter % report == 0 || !running)
            _report(niter, nsqrt, residual, xmax, xhat_res_sq, x_res_sq)
        end

        if lb_flag && (niter % lower_bound == 0 || !running)
            (lb, gap) = @timeit(ph_data.time_info,
                                "Update Gap",
                                update_gap(ph_data, worker_inf, niter)
                                )
            if report_flag
                _report_lower_bound(niter, lb, gap)
            end
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
