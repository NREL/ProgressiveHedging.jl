
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

# function compute_start_points(phd::PHData)::Nothing

#     @sync for (scen, model) in pairs(phd.submodels)
#         proc = phd.scen_proc_map[scen]
#         @spawnat(proc, JuMP.optimize!(fetch(model)))
#     end

#     for (scen, model) in pairs(phd.submodels)
#         proc = phd.scen_proc_map[scen]
#         # MOI refers to the MathOptInterface package. Apparently this is made
#         # accessible by JuMP since it is not imported here
#         sts = fetch(@spawnat(proc, JuMP.termination_status(fetch(model))))
#         if sts != MOI.OPTIMAL && sts != MOI.LOCALLY_SOLVED &&
#             sts != MOI.ALMOST_LOCALLY_SOLVED
#             @error("Initialization solve for scenario $scen on process $proc " *
#                    "returned $sts.")
#         end
#     end
    
#     return
# end

function _augment_objective_w(obj::JuMP.GenericQuadExpr{Float64,V},
                              model::M,
                              var_dict::Dict{VariableID,VariableInfo},
                              ) where {V <: JuMP.AbstractVariableRef,
                                       M <: JuMP.AbstractModel}

    w_dict = Dict{VariableID,JuMP.variable_type(model)}()
    jvi = JuMP.VariableInfo(false, NaN,   # lower_bound
                            false, NaN,   # upper_bound
                            true, 0.0,    # fixed
                            false, NaN,   # start value
                            false, false) # binary, integer

    for (vid, vinfo) in pairs(var_dict)
        w_ref = JuMP.add_variable(model,
                                  JuMP.build_variable(_error, jvi))
        w_dict[vid] = w_ref
        x_ref = fetch(vinfo.ref)
        JuMP.add_to_expression!(obj, w_ref*x_ref)
    end
    
    return w_dict
end

function _augment_objective_xhat(obj::JuMP.GenericQuadExpr{Float64,V},
                                 model::M,
                                 r::R,
                                 var_dict::Dict{VariableID,VariableInfo},
                                 ) where {V <: JuMP.AbstractVariableRef,
                                          M <: JuMP.AbstractModel,
                                          R <: Real}

    xhat_dict = Dict{VariableID,JuMP.variable_type(model)}()
    jvi = JuMP.VariableInfo(false, NaN,   # lower_bound
                            false, NaN,   # upper_bound
                            true, 0.0,    # fixed
                            false, NaN,   # start value
                            false, false) # binary, integer

    for (vid, vinfo) in pairs(var_dict)
        xhat_ref = JuMP.add_variable(model,
                                     JuMP.build_variable(_error, jvi))
        xhat_dict[vid] = xhat_ref
        x_ref = fetch(vinfo.ref)
        JuMP.add_to_expression!(obj, 0.5 * r * (x_ref - xhat_ref)^2)
    end

    return xhat_dict
end

function _augment_objective(model::M,
                           r::R,
                           var_dict::Dict{VariableID,VariableInfo}
                           ) where {M <: JuMP.AbstractModel,
                                    R <: Real}
    obj = JuMP.objective_function(model,
                                  JuMP.GenericQuadExpr{Float64,
                                                       JuMP.variable_type(model)})
    JuMP.set_objective_function(model, 0.0)

    w_refs = _augment_objective_w(obj, model, var_dict)
    xhat_refs = _augment_objective_xhat(obj, model, r, var_dict)

    JuMP.set_objective_function(model, obj)

    return (w_refs, xhat_refs)
end

function order_augment(phd::PHData)::Dict{ScenarioID,Future}

    ref_map = Dict{ScenarioID, Future}()

    # Create variables and augment objectives
    @sync for (scid, sinfo) in pairs(phd.scenario_map)
        r = phd.r
        model = sinfo.model
        var_map = sinfo.branch_map

        ref_map[scid] = @spawnat(sinfo.proc,
                                 _augment_objective(fetch(model),
                                                    r,
                                                    var_map))
    end

    return ref_map
end

function retrieve_ph_refs(phd::PHData,
                          ref_map::Dict{ScenarioID, Future})::Nothing

    @sync for (nid, node) in pairs(phd.scenario_tree.tree_map)

        if is_leaf(node)
            continue
        end
        
        for scid in node.scenario_bundle

            sinfo = phd.scenario_map[scid]
            vrefs = ref_map[scid]

            for i in node.variable_indices

                vid = VariableID(node.stage, i)
                sinfo.W[vid].ref = @spawnat(sinfo.proc,
                                            get(fetch(vrefs)[1], vid, nothing))

                xid = XhatID(nid, i)
                sinfo.Xhat[xid].ref = @spawnat(sinfo.proc,
                                               get(fetch(vrefs)[2], vid, nothing))

            end
        end
    end

    return
end

function augment_objectives(phd::PHData)::Nothing

    # Tell the processes to augment their objective functions
    ref_map = @timeit(phd.time_info, "Add penalty term", order_augment(phd))

    # Retrieve references for all the new PH variables
    @timeit(phd.time_info, "Retrieve variable references", retrieve_ph_refs(phd, ref_map))

    return
end

include("sj_setup.jl")
include("dir_setup.jl")
