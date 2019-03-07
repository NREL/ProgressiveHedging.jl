
function compute_and_save_xhat(phd::PHData)

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)

        xhat = 0.0
        norm = 0.0

        for i in node.variable_indices
            
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

            for s in node.scenario_bundle
                var_id = VariableID(s, node.stage, i)
                kx = value(phd, var_id) - xhat
                phd.W[var_id] += phd.r * kx
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
