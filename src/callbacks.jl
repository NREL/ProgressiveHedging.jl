

#### Canned Callbacks ####

"""
    variable_fixing(; lag=2, eq_tol=1e-8)::Callback

Implementation of the variable fixing convergence acceleration heuristic in section 2.2 of (Watson & Woodruff 2010).
"""
function variable_fixing(; lag=2, eq_tol=1e-8)::Callback
    ext = Dict{Symbol,Any}()
    ext[:lag] = lag
    ext[:eq_tol] = eq_tol
    return Callback("variable_fixing",
                    _variable_fixing,
                    _variable_fixing_init,
                    ext)
end

function _variable_fixing_init(external::Dict{Symbol,Any}, phd::PHData)

    # Between iterations
    external[:value_count] = Dict{XhatID,Int}(
        xhid => 0 for xhid in keys(consensus_variables(phd))
    )
    external[:value] = Dict{XhatID,Float64}(
        xhid => value(xhat) for (xhid,xhat) in pairs(consensus_variables(phd))
    )
    external[:fixed] = Set{XhatID}()

    return
end

function _variable_fixing(external::Dict{Symbol,Any},
                          phd::PHData,
                          winf::WorkerInf,
                          niter::Int)::Bool

    lag = external[:lag]
    nscen = length(scenarios(phd))
    limit = lag * nscen

    if niter >= limit

        values = external[:value]
        counts = external[:value_count]
        fixed = external[:fixed]
        tol = external[:eq_tol]
        to_fix = Dict{ScenarioID,Dict{VariableID,Float64}}()

        for (xhid, xhat) in pairs(consensus_variables(phd))

            if xhid in fixed
                continue
            end

            is_equal = true
            for vid in variables(xhat)
                is_equal &= isapprox(value(xhat), branch_value(phd, vid), atol=tol)
            end

            if is_equal

                counts[xhid] = nrepeats = counts[xhid] + 1

                if nrepeats >= limit

                    for vid in variables(xhat)

                        scen = scenario(vid)

                        if !haskey(to_fix, scen)
                            to_fix[scen] = Dict{VariableID,Float64}()
                        end

                        to_fix[scen][vid] = value(xhat)
                    end

                    push!(fixed, xhid)

                end

            else

                values[xhid] = value(xhat)
                counts[xhid] = 1

            end

        end

        for (scen, value_dict) in pairs(to_fix)
            apply_to_subproblem(fix_variables, phd, winf, scen, (value_dict,))
        end

    end
    
    return true
end

"""
    mean_deviation(;tol::Float64=1e-8,
                   save_deviations::Bool=false
                   )::Callback

Implementation of a termination criterion given in section 2.3 of (Watson & Woodruff 2010). There it is called 'td'.
"""
function mean_deviation(;tol::Float64=1e-8,
                        save_deviations::Bool=false
                        )::Callback
    ext = Dict{Symbol,Any}(:tol => tol, :save => save_deviations)

    if save_deviations
        ext[:deviations] = Dict{Int,Float64}()
    end

    return Callback("mean_deviation",
                    _mean_deviation,
                    ext
                    )
end

function _mean_deviation(external::Dict{Symbol,Any},
                         phd::PHData,
                         winf::WorkerInf,
                         niter::Int)::Bool

    nscen = length(scenarios(phd))

    td = 0.0
    for (xhid, xhat) in consensus_variables(phd)
        deviation = 0.0
        for vid in variables(xhat)
            deviation += abs(branch_value(phd, vid) - value(xhat))
        end
        td += deviation / (value(xhat))
    end
    td /= nscen

    if external[:save]
        external[:deviations][niter] = td
    end

    return external[:tol] < td
end
