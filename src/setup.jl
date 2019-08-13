
function _error(astring::String)
    return
end

function assign_scenarios_to_procs(scen_tree::ScenarioTree)::Dict{ScenarioID,Int}
    sp_map = Dict{ScenarioID, Int}()

    nprocs = Distributed.nworkers()
    wrks = workers()
    for (k,s) in enumerate(scenarios(scen_tree))
        sp_map[s] = wrks[(k-1) % nprocs + 1]
    end

    return sp_map
end

function compute_start_points(phd::PHData)::Nothing
    
    @sync for (scen, model) in pairs(phd.submodels)
        proc = phd.scen_proc_map[scen]
        @spawnat(proc, JuMP.optimize!(fetch(model)))
    end

    for (scen, model) in pairs(phd.submodels)
        proc = phd.scen_proc_map[scen]
        # MOI refers to the MathOptInterface package. Apparently this is made
        # accessible by JuMP since it is not imported here
        sts = fetch(@spawnat(proc, JuMP.termination_status(fetch(model))))
        if sts != MOI.OPTIMAL && sts != MOI.LOCALLY_SOLVED &&
            sts != MOI.ALMOST_LOCALLY_SOLVED
            @error("Initialization solve for scenario $scen on process $proc " *
                   "returned $sts.")
        end
    end
    
    return
end

function get_objective_as_quadratic(model::M) where M <: JuMP.AbstractModel
    model_obj = JuMP.objective_function(model)
    if typeof(model_obj) <: JuMP.GenericQuadExpr
        obj = model_obj
    else
        obj = zero(JuMP.GenericQuadExpr{Float64, JuMP.variable_type(model)})
        JuMP.add_to_expression!(obj, model_obj)
    end
    return obj
end

function augment_objective_w(model::M,
                             scen::ScenarioID,
                             last_stage::StageID,
                             var_dict::Dict{VariableID,VariableInfo},
                             ) where M <: JuMP.AbstractModel

    w_dict = Dict{VariableID,JuMP.variable_type(model)}()
    obj = get_objective_as_quadratic(model)
    jvi = JuMP.VariableInfo(false, NaN,   # lower_bound
                            false, NaN,   # upper_bound
                            true, 0.0,    # fixed
                            false, NaN,   # start value
                            false, false) # binary, integer

    for (vid, vinfo) in pairs(var_dict)
        if vid.scenario == scen && vid.stage != last_stage
            w_ref = JuMP.add_variable(model,
                                      JuMP.build_variable(_error, jvi))
            w_dict[vid] = w_ref
            x_ref = fetch(vinfo.ref)
            JuMP.add_to_expression!(obj, w_ref*x_ref)
        end
    end

    JuMP.set_objective_function(model, obj)
    
    return w_dict
end

function augment_objective_xhat(model::M,
                                r::R,
                                scen::ScenarioID,
                                last_stage::StageID,
                                var_dict::Dict{VariableID,VariableInfo},
                                ) where {M <: JuMP.AbstractModel,
                                         R <: Real}

    xhat_dict = Dict{VariableID,JuMP.variable_type(model)}()
    obj = get_objective_as_quadratic(model)
    jvi = JuMP.VariableInfo(false, NaN,   # lower_bound
                            false, NaN,   # upper_bound
                            true, 0.0,    # fixed
                            false, NaN,   # start value
                            false, false) # binary, integer

    for (vid, vinfo) in pairs(var_dict)
        if vid.scenario == scen && vid.stage != last_stage
            xhat_ref = JuMP.add_variable(model,
                                         JuMP.build_variable(_error, jvi))
            xhat_dict[vid] = xhat_ref
            x_ref = fetch(vinfo.ref)
            JuMP.add_to_expression!(obj, 0.5 * r * (x_ref - xhat_ref)^2)
        end
    end

    JuMP.set_objective_function(model, obj)
    
    return xhat_dict
end

function augment_objective(model::M,
                           r::R,
                           scen::ScenarioID,
                           last_stage::StageID,
                           var_dict::Dict{VariableID,VariableInfo}
                           ) where {M <: JuMP.AbstractModel,
                                    R <: Real}
    w_refs = augment_objective_w(model, scen, last_stage, var_dict)
    xhat_refs = augment_objective_xhat(model, r, scen, last_stage, var_dict)
    return (w_refs, xhat_refs)
end

function copy_subset(vdict::Dict{VariableID,VariableInfo},
                     scen::ScenarioID,
                     last::StageID)
    thecopy = Dict{VariableID,VariableInfo}()
    for (vid,vinfo) in pairs(vdict)
        if vid.scenario == scen && vid.stage != last
            thecopy[vid] = vinfo
        end
    end
    return thecopy
end

function order_augment(phd::PHData)::Dict{ScenarioID,Future}
    last = last_stage(phd.scenario_tree)

    ref_map = Dict{ScenarioID, Future}()

    # Create variables and augment objectives
    @sync for (scid, model) in pairs(phd.submodels)
        proc = phd.scen_proc_map[scid]

        var_map = copy_subset(phd.variable_map, scid, last)

        ref_map[scid] = @spawnat(proc,
                                 augment_objective(fetch(model),
                                                   phd.r,
                                                   scid,
                                                   last,
                                                   var_map))
    end

    return ref_map
end

function retrieve_ph_refs(phd::PHData,
                          ref_map::Dict{ScenarioID, Future})::Nothing
    last = last_stage(phd.scenario_tree)

    @sync for (nid, node) in pairs(phd.scenario_tree.tree_map)

        if node.stage == last
            continue
        end
        
        for scid in node.scenario_bundle

            proc = phd.scen_proc_map[scid]
            vrefs = ref_map[scid]

            for i in node.variable_indices

                vid = VariableID(scid, node.stage, i)
                phd.W_ref[vid] = @spawnat(proc, get(fetch(vrefs)[1],vid,nothing))

                xid = XhatID(nid, i)
                if !(xid in keys(phd.Xhat_ref))
                    phd.Xhat_ref[xid] = Dict{ScenarioID, Future}()
                end
                phd.Xhat_ref[xid][scid] = @spawnat(proc, get(fetch(vrefs)[2],
                                                             vid,
                                                             nothing))

            end
        end
    end

    return
end

function augment_objectives(phd::PHData)::Nothing

    # Tell the processes to augment their objective functions
    ref_map = @time order_augment(phd)

    # Retrieve references for all the new PH variables
    @time retrieve_ph_refs(phd, ref_map)

    return
end

include("sj_setup.jl")
include("dir_setup.jl")
