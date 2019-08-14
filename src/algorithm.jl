
function retrieve_values(phd::PHData, leaf::Bool)::Nothing
    last = last_stage(phd.scenario_tree)
    for (vid, vinfo) in pairs(phd.variable_map)
        if xor(vid.stage != last, leaf)
            vinfo.value = _fetch_variable_value(phd, vid.scenario, vinfo)
        end
    end
    return
end

function compute_and_save_xhat(phd::PHData, leaf::Bool)::Float64

    xhat_res = 0.0
    # xhat_olds = Dict{XhatID,Float64}()
    last = last_stage(phd.scenario_tree)

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)

        if xor(node.stage == last, leaf)
            continue
        end

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

    # This element of the residual was causing convergence issues so
    # leave it as zero for now

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

function compute_and_save_w(phd::PHData, leaf::Bool)::Nothing

    last = last_stage(phd.scenario_tree)

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)

        if xor(node.stage == last, leaf)
            continue
        end

        for i in node.variable_indices

            xhat = phd.Xhat[XhatID(node_id,i)]
            
            exp = 0.0
            norm = 0.0

            for s in node.scenario_bundle
                var_id = VariableID(s, node.stage, i)
                kx = value(phd, var_id) - xhat
                phd.W[var_id] += phd.r * kx

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

function update_ph_variables(phd::PHData)::Float64
    retrieve_values(phd, false)
    xhat_residual = compute_and_save_xhat(phd, false)
    compute_and_save_w(phd, false)
    return xhat_residual
end

function update_ph_leaf_variables(phd::PHData)::Nothing
    retrieve_values(phd, true)
    compute_and_save_xhat(phd, true)
    compute_and_save_w(phd, true)
    return
end

function set_start_values(phd::PHData)::Nothing

    @sync for (var_id, var_info) in pairs(phd.variable_map)

        ref = var_info.ref

        @spawnat(phd.scen_proc_map[var_id.scenario],
                 JuMP.set_start_value(fetch(ref), JuMP.value(fetch(ref)))
                 )
    end

    return

end

function compute_x_residual(phd::PHData)::Float64

    kxsq = 0.0

    for (node_id, node) in pairs(phd.scenario_tree.tree_map)
        for i in node.variable_indices
            
            xhat = phd.Xhat[XhatID(node_id, i)]
            
            for s in node.scenario_bundle

                x = value(phd, VariableID(s, node.stage, i))
                kxsq += phd.probabilities[s] * (x - xhat)^2

            end
        end
    end
    
    return kxsq
end

function fix_values(ref_val_dict::Dict{Future, Float64})::Nothing

    for (fref, val) in pairs(ref_val_dict)
        JuMP.fix(fetch(fref), val, force=true)
    end

    return
end

function sort_w_by_scenario(phd::PHData)::Dict{ScenarioID,Dict{Future,Float64}}
    rv_dict = Dict{ScenarioID,Dict{Future,Float64}}()

    last = last_stage(phd.scenario_tree)
    for (w_id, value) in phd.W
        if w_id.stage == last
            continue
        end

        s = w_id.scenario
        if !haskey(rv_dict, s)
            rv_dict[s] = Dict{Future,Float64}()
        end

        rv_dict[s][phd.W_ref[w_id]] = value
    end
    
    return rv_dict
end

function sort_xhat_by_scenario(phd::PHData)::Dict{ScenarioID,Dict{Future,Float64}}

    rv_dict = Dict{ScenarioID,Dict{Future,Float64}}()
    last = last_stage(phd.scenario_tree)

    for (xhat_id, scen_bundle) in pairs(phd.Xhat_ref)

        if stage_id(xhat_id, phd) == last
            continue
        end

        value = phd.Xhat[xhat_id]

        for (s, ref) in pairs(scen_bundle)
            if !haskey(rv_dict, s)
                rv_dict[s] = Dict{Future,Float64}()
            end

            rv_dict[s][ref] = value
        end
    end
    
    return rv_dict
end

function fix_ph_variables(phd::PHData)::Nothing
    w_scen_dict = sort_w_by_scenario(phd)
    xhat_scen_dict = sort_xhat_by_scenario(phd)

    @sync for (scid, model) in pairs(phd.submodels)
        w_dict = w_scen_dict[scid]
        xhat_dict = xhat_scen_dict[scid]

        @spawnat(phd.scen_proc_map[scid], fix_values(w_dict))
        @spawnat(phd.scen_proc_map[scid], fix_values(xhat_dict))
    end

    return
end

function solve_subproblems(phd::PHData)

    # Find subproblem solutions--in parallel if we have the workers for it.  @sync
    # will wait for all processes to complete
    @sync for (scen, model) in pairs(phd.submodels)
        @spawnat(phd.scen_proc_map[scen], JuMP.optimize!(fetch(model)))
    end

    for (scen, model) in pairs(phd.submodels)
        proc = phd.scen_proc_map[scen]
        # MOI refers to the MathOptInterface package. Apparently this is made
        # accessible by JuMP since it is not imported here
        sts = fetch(@spawnat(proc, JuMP.termination_status(fetch(model))))
        if sts != MOI.OPTIMAL && sts != MOI.LOCALLY_SOLVED &&
            sts != MOI.ALMOST_LOCALLY_SOLVED
            @error("Scenario $scen subproblem returned $sts.")
        end
    end
end

function hedge(ph_data::PHData, max_iter=100, atol=1e-8, report=false)
    niter = 0
    residual = atol + 1.0e10
    report_interval = Int(floor(max_iter / max_iter))

    if report
        x_residual = compute_x_residual(ph_data)
        println("Iter: $niter   Err: $x_residual")
    end
    
    while niter < max_iter && residual > atol
        
        # Set initial values, fix cross model values (W and Xhat) and
        # solve the subproblems

        # Setting start values causes issues with some solvers
        # set_start_values(ph_data)
        println("...fixing PH variables...")
        @time fix_ph_variables(ph_data)

        println("...solving subproblems...")
        @time solve_subproblems(ph_data)

        # Update xhat and w
        println("...updating ph variables...")
        xhat_residual = @time update_ph_variables(ph_data)

        # Update stopping criteria -- xhat_residual measures the movement of
        # xhat values from k^th iteration to the (k+1)^th iteration while
        # x_residual measures the disagreement between the x variables and
        # its corresponding xhat variable (so lack of consensus amongst the
        # subproblems or violation of the nonanticipativity constraint)
        println("...computing residual...")
        x_residual = @time compute_x_residual(ph_data)
        residual = sqrt(xhat_residual + x_residual)
        
        niter += 1

        if report && niter % report_interval == 0 && niter != max_iter
            # retrieve_values(ph_data, true)
            # obj = retrieve_obj_value(ph_data)
            # println("Iter: $niter   Xhat_res^2: $xhat_residual   X_res^2: $x_residual    Obj: $obj")
            println("Iter: $niter   Xhat_res^2: $xhat_residual   X_res^2: $x_residual")
        end
    end

    println("...updating leaf PH variables...")
    @time update_ph_leaf_variables(ph_data)

    if niter >= max_iter
        @warn("Performed $niter iterations without convergence. " *
              "Consider increasing max_iter from $max_iter.")
    end

    return (niter, residual)
end
