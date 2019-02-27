
function compute_and_save_xhat(phd::PHData)

    for (var, info) in pairs(phd.params.variable_map)
        
        xhat = 0.0
        norm = 0.0

        for s in info.scenario_bundle
            submodel = phd.submodels[s]
            
            p = phd.params.probs[s]
            value = get_value(submodel, var)
            xhat += p * value
            norm += p
        end
        xhat = xhat / norm

        for s in info.scenario_bundle
            phd.Xhat[Tuple([s, var])] = xhat
        end
        
    end

end

function compute_and_save_w(phd::PHData)

    for (var, info) in pairs(phd.params.variable_map)
        
        # Want this value instead of that stored in phd.Xhat as the value stored
        # in phd.Xhat is the (ν + 1) iteration value rather than the
        # ν iteration value
        Xhat = get_fix_value(phd.submodels[first(info.scenario_bundle)],
                             "Xhat_" * var)

        for s in info.scenario_bundle
            submodel = phd.submodels[s]
            
            kx = get_value(submodel, var) - Xhat
            phd.W[Tuple([s, var])] = (get_fix_value(submodel, "W_" * var)
                                    + phd.params.r * kx)
        end
        
    end

end

function set_start_values(phd)

    for (var, info) in pairs(phd.params.variable_map)
        for s in info.scenario_bundle
            submodel = phd.submodels[s]
            vref = JuMP.variable_by_name(submodel, var)
            JuMP.set_start_value(vref, JuMP.value(vref))
        end
    end

    return

end

function compute_residual(phd::PHData)
    kxsq = 0.0
    for (var, info) in pairs(phd.params.variable_map)
        for s in info.scenario_bundle
            model = phd.submodels[s]
            kxsq += (get_value(model, var) - get_fix_value(model, "Xhat_" * var))^2
        end
    end
    return sqrt(kxsq)
end

function compute_and_save_values(phd::PHData)

    compute_and_save_xhat(phd)
    compute_and_save_w(phd)
    set_start_values(phd)
    res = compute_residual(phd)

    return res
end

function fix_xhat(phd::PHData)

    for (var, info) in pairs(phd.params.variable_map)
        for s in info.scenario_bundle
            xhat_ref = JuMP.variable_by_name(phd.submodels[s], "Xhat_" * var)
            JuMP.fix(xhat_ref, phd.Xhat[Tuple([s,var])], force=true)
        end
    end
    
    return
end

function fix_w(phd::PHData)

    for (var, info) in pairs(phd.params.variable_map)
        for s in info.scenario_bundle
            w_ref = JuMP.variable_by_name(phd.submodels[s], "W_" * var)
            JuMP.fix(w_ref, phd.W[Tuple([s,var])], force=true)
        end
    end
    
    return
end

function solve_subproblems(phd::PHData)

    # Find subproblem solutions--this is parallelizable
    for (scen, model) in pairs(phd.submodels)
        JuMP.optimize!(model)

        # MOI refers to the MathOptInterface package. Apparently this is made
        # accessible by JuMP since it is not imported here
        sts = JuMP.termination_status(model)
        if sts != MOI.OPTIMAL && sts != MOI.LOCALLY_SOLVED
            @error("Scenario $scen subproblem returned $sts.")
        end
    end
end
