

#### Canned Callbacks ####

function variable_reduction(; lag=2, eq_tol=1e-8)::Callback
    ext = Dict{Symbol,Any}()
    ext[:lag] = lag
    ext[:eq_tol] = eq_tol
    return Callback("variable_reduction",
                    _variable_reduction,
                    _variable_reduction_init,
                    ext)
end

function _variable_reduction_init(external::Dict{Symbol,Any}, phd::PHData)

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

function _variable_reduction(external::Dict{Symbol,Any},
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
        to_fix = Dict{ScenarioID,Dict{VariableID,Float64}}()

        for (xhid, xhat) in pairs(consensus_variables(phd))

            if xhid in fixed
                continue
            end

            is_equal = true
            for vid in variables(xhat)
                is_equal &= isapprox(value(xhat), branch_value(phd, vid), atol=1e-8)
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

function mean_absolute_deviation(external::Dict{Symbol,Any},
                                 phd::PHData,
                                 niter::Int)::Bool
    # TODO: Implement this function
    return true
end
