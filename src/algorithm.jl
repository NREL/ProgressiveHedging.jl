
function compute_and_save_xhat(phd::PHData)

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)

        for i in node.variable_indices

            xhat = 0.0
            norm = 0.0
            
            for s in node.scenario_bundle
                
                p = phd.probabilities[s]
                x = value(phd, s, node.stage, i)

                # println("Variable: ",
                #         phd.variable_map[VariableID(s, node.stage, i)].ref)
                # println("Scenario: ", s)
                # println("Stage: ", node.stage)
                # println("Index: ", i)
                # println("Prob: ", p)
                # println("Value: ", x)
                
                xhat += p * x
                norm += p
                
            end

            # if length(node.scenario_bundle) == 2
            #     s = first(node.scenario_bundle)
            #     println("****************************")
            #     println("Variable: ", phd.variable_map[VariableID(s, node.stage, i)].ref)
            #     println("Hat value: ", xhat/norm)
            #     val_str = "Values: ("
            #     for s in node.scenario_bundle
            #         val_str *= string(value(phd, s, node.stage, i)) * ", "
            #     end
            #     val_str = strip(val_str, [' ',','])
            #     val_str *= ")"
            #     println(val_str)
            #     println("****************************")
            # end

            # println("Xhat Value: ", xhat/norm)
            
            phd.Xhat[XhatID(node_id,i)] = xhat / norm
        end
    end

    return
end

function compute_and_save_w(phd::PHData)

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)
        for i in node.variable_indices

            xhat = phd.Xhat[XhatID(node_id,i)]
            
            exp = 0.0
            norm = 0.0

            # if length(node.scenario_bundle) == 2
            #     s = first(node.scenario_bundle)
            #     println("----------------------------")
            #     println("Variable: ", phd.variable_map[VariableID(s, node.stage, i)].ref)
            #     println("Hat value: ", xhat)
            #     val_str = "Values: ("
            #     kx_str = "KX: ("
            #     for s in node.scenario_bundle
            #         val_str *= string(value(phd, s, node.stage, i)) * ", "
            #         kx_str *= string(value(phd, s, node.stage, i) - xhat) * ", "
            #     end
            #     val_str = strip(val_str, [' ',','])
            #     kx_str = strip(kx_str, [' ',','])
            #     val_str *= ")"
            #     kx_str *= ")"
            #     println(val_str)
            #     println(kx_str)
            #     println("----------------------------")
            # end


            # TODO: Decide whether to keep this or not...
            for s in node.scenario_bundle
                var_id = VariableID(s, node.stage, i)
                kx = value(phd, var_id) - xhat
                phd.W[var_id] += phd.r * kx

                p = phd.probabilities[s]
                exp += p * phd.W[var_id]
                norm += p
            end

            if abs(exp) > 1e-12
                @warn("Conditional expectation of " *
                      "W[$(node.scenario_bundle),$(node.stage),$i] is non-zero: " *
                      string(exp/norm))
            end
        end
    end

    return
end

function set_start_values(phd)

    for (var_id, var_info) in pairs(phd.variable_map)
        JuMP.set_start_value(var_info.ref, JuMP.value(var_info.ref))
    end

    return

end

function compute_residual(phd::PHData)
    kxsq = 0.0
    
    for (node_id, node) in pairs(phd.scenario_tree.tree_map)
        for i in node.variable_indices
            
            xhat = phd.Xhat[XhatID(node_id, i)]
            
            for s in node.scenario_bundle
                var_id = VariableID(s, node.stage, i)
                x = JuMP.value(phd.variable_map[var_id].ref)
                kxsq += (x - xhat)^2
            end
        end
    end
    
    return sqrt(kxsq)
end

function fix_xhat(phd::PHData)

    for (xhat_id, value) in phd.Xhat
        for xhat_ref in phd.Xhat_ref[xhat_id]
            JuMP.fix(xhat_ref, value, force=true)
        end
    end
    
    return
end

function fix_w(phd::PHData)

    for (w_id, value) in phd.W
        JuMP.fix(phd.W_ref[w_id], value, force=true)
    end
    
    return
end

function fix_ph_variables(phd::PHData)
    fix_w(phd)
    fix_xhat(phd)
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

function hedge(ph_data::PHData, max_iter=100, atol=1e-8)
    niter = 0
    residual = atol + 1.0e10
    
    while niter < max_iter && residual > atol
        
        # Set initial values, fix cross model values (W and Xhat) and
        # solve the subproblems
        set_start_values(ph_data)
        fix_ph_variables(ph_data)
        solve_subproblems(ph_data)

        # Update Xhat values
        compute_and_save_xhat(ph_data)

        # Update W values
        compute_and_save_w(ph_data)

        # Update stopping criteria
        residual = compute_residual(ph_data)
        niter += 1
    end

    if niter >= max_iter
        @warn("Performed $niter iterations without convergence. " *
              "Consider increasing max_iter from $max_iter.")
    end

    return (niter, residual)
end
