
function compute_and_save_xhat(phd::PHData)::Float64

    xhat_res = 0.0
    # xhat_olds = Dict{XhatID,Float64}()

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)

        for i in node.variable_indices

            xhat = 0.0
            norm = 0.0
            
            for s in node.scenario_bundle
                
                p = phd.probabilities[s]
                x = value(phd, s, node.stage, i)

                xhat += p * x
                norm += p
                
            end

            xhat_id = XhatID(node_id,i)
            # xhat_old = phd.Xhat[xhat_id]
            xhat_new = xhat / norm

            phd.Xhat[xhat_id] = xhat_new

            # xhat_res += norm * (xhat_new - xhat_old)^2

            # xhat_olds[xhat_id] = xhat_old
        end
    end

    # xhat_res = 0.0
    # for (xhat_id, xhat) in pairs(phd.Xhat)
        
    #     nid = xhat_id.node
    #     node = phd.scenario_tree.tree_map[nid]
        
    #     for s in node.scenario_bundle
    #         xhat_res += phd.probabilities[s] * (xhat - xhat_olds[xhat_id])^2
    #     end
    # end
        

    return xhat_res
end

function compute_and_save_w(phd::PHData)

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)
        for i in node.variable_indices

            xhat = phd.Xhat[XhatID(node_id,i)]
            
            exp = 0.0
            norm = 0.0

            for s in node.scenario_bundle
                var_id = VariableID(s, node.stage, i)
                kx = value(phd, var_id) - xhat
                phd.W[var_id] += phd.r * kx

                # TODO: Decide whether to keep this or not...
                p = phd.probabilities[s]
                exp += p * phd.W[var_id]
                norm += p
            end

            if abs(exp) > 1e-6
                @warn("Conditional expectation of " *
                      "W[$(node.scenario_bundle),$(node.stage),$i] " *
                      "is non-zero: " * string(exp/norm))
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

function compute_x_residual(phd::PHData)::Float64
    kxsq = 0.0
    
    for (node_id, node) in pairs(phd.scenario_tree.tree_map)
        for i in node.variable_indices
            
            xhat = phd.Xhat[XhatID(node_id, i)]
            
            for s in node.scenario_bundle
                var_id = VariableID(s, node.stage, i)
                x = JuMP.value(phd.variable_map[var_id].ref)
                kxsq += phd.probabilities[s] * (x - xhat)^2
            end
        end
    end
    
    return kxsq
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

function hedge(ph_data::PHData, max_iter=100, atol=1e-8, report=false)
    niter = 0
    residual = atol + 1.0e10
    report_interval = Int(max_iter / 10)

    if report
        x_residual = compute_x_residual(ph_data)
        println("Iter: $niter   Err: $x_residual")
    end
    
    while niter < max_iter && residual > atol
        
        # Set initial values, fix cross model values (W and Xhat) and
        # solve the subproblems
        set_start_values(ph_data)
        fix_ph_variables(ph_data)
        solve_subproblems(ph_data)

        # Update Xhat values
        xhat_residual = compute_and_save_xhat(ph_data)

        # Update W values
        compute_and_save_w(ph_data)

        # Update stopping criteria -- xhat_residual measures the movement of
        # xhat values from k^th iteration to the (k+1)^th iteration while
        # x_residual measures the disagreement between the x variables and
        # its corresponding xhat variable (so lack of consensus amongst the
        # subproblems or violation of the nonanticipativity constraint)
        x_residual = compute_x_residual(ph_data)
        residual = sqrt(xhat_residual + x_residual)
        
        niter += 1

        if report && niter % report_interval == 0 && niter != max_iter
            obj = retrieve_obj_value(ph_data)
            println("Iter: $niter   Xhat_res: $xhat_residual   X_res: $x_residual    Obj: $obj")
        end
    end

    if niter >= max_iter
        @warn("Performed $niter iterations without convergence. " *
              "Consider increasing max_iter from $max_iter.")
    end

    return (niter, residual)
end
