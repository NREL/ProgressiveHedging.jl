
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

function _create_model(sint::Int,
                       model_constructor::Function,
                       model_constructor_args::Tuple,
                       model_type::Type{M};
                       kwargs...
                       ) where {M <: JuMP.AbstractModel}

    model = model_constructor(sint,
                              model_constructor_args...;
                              kwargs...)

    if typeof(model) != model_type
        @error("Model constructor function produced model of type " *
               typeof(model) * ". " *
               "Expected model of type $(model_type). " *
               "Undefined behavior will probably result.")
    end

    return model
end
    

function create_models(scen_tree::ScenarioTree,
                       model_constructor::Function,
                       model_constructor_args::Tuple,
                       scen_proc_map::Dict{ScenarioID, Int},
                       model_type::Type{M};
                       kwargs...
                       ) where {M <: JuMP.AbstractModel}

    submodels = Dict{ScenarioID,Future}()

    @sync for s in scenarios(scen_tree)
        proc = scen_proc_map[s]
        sint = _value(s)
        submodels[s] = @spawnat(proc,
                                _create_model(sint,
                                              model_constructor,
                                              model_constructor_args,
                                              model_type;
                                              kwargs...
                                              )
                                )
    end

    return submodels

end

function collect_variable_refs(scen_tree::ScenarioTree,
                               scen_proc_map::Dict{ScenarioID, Int},
                               submodels::Dict{ScenarioID, Future},
                               variable_dict::Dict{STAGE_ID,Vector{String}},
                               ) where {M <: JuMP.AbstractModel}

    var_map = Dict{ScenarioID, Dict{VariableID,VariableInfo}}()
    for scid in scenarios(scen_tree)
        var_map[scid] = Dict{VariableID, VariableInfo}()
    end

    @sync for (nid, node) in pairs(scen_tree.tree_map)

        @assert(_value(node.stage) in keys(variable_dict))

        for var_name in variable_dict[_value(node.stage)]
            idx = next_index(node)

            for s in node.scenario_bundle

                vid = VariableID(node.stage, idx)
                proc = scen_proc_map[s]
                model = submodels[s]

                ref = @spawnat(proc, JuMP.variable_by_name(fetch(model), var_name))
                var_map[s][vid] = VariableInfo(ref, var_name, nid)

            end
        end
    end

    return var_map
end 

function build_submodels(scen_tree::ScenarioTree,
                         model_constructor::Function,
                         model_constructor_args::Tuple,
                         variable_dict::Dict{STAGE_ID,Vector{String}},
                         model_type::Type{M},
                         timo::TimerOutputs.TimerOutput;
                         kwargs...
                         ) where {M <: JuMP.AbstractModel}

    # Assign each subproblem to a particular juila process
    scen_proc_map = assign_scenarios_to_procs(scen_tree)

    # Construct the models
    submodels = @timeit(timo, "Create models",
                        create_models(scen_tree,
                                      model_constructor,
                                      model_constructor_args,
                                      scen_proc_map,
                                      model_type;
                                      kwargs...)
                        )
    # Store variable references and other info
    var_map = @timeit(timo, "Collect variables",
                      collect_variable_refs(scen_tree,
                                            scen_proc_map,
                                            submodels,
                                            variable_dict)
                      )

    return (submodels, scen_proc_map, var_map)
end

function initialize(scenario_tree::ScenarioTree,
                    model_constructor::Function,
                    variable_dict::Dict{STAGE_ID,Vector{String}},
                    r::R,
                    model_type::Type{M},
                    timo::TimerOutputs.TimerOutput,
                    report::Bool,
                    constructor_args::Tuple;
                    kwargs...
                    )::PHData where {S <: AbstractString,
                                     R <: Real,
                                     M <: JuMP.AbstractModel}

    scen_tree = deepcopy(scenario_tree)

    if report
        println("...building submodels...")
        flush(stdout)
    end

    (submodels, scen_proc_map, var_map
     ) = @timeit(timo, "Submodel construction",
                 build_submodels(scen_tree,
                                 model_constructor,
                                 constructor_args,
                                 variable_dict,
                                 M,
                                 timo;
                                 kwargs...)
                 )

    ph_data = PHData(r,
                     scen_tree,
                     scen_proc_map,
                     scen_tree.prob_map,
                     submodels,
                     var_map,
                     timo)

    if report
        println("...computing starting values...")
        flush(stdout)
    end
    @timeit(timo, "Compute start values", solve_subproblems(ph_data))

    if report
        println("...updating ph variables...")
        flush(stdout)
    end
    @timeit(timo, "Initialize PH variables", update_ph_variables(ph_data))

    if report
        println("...augmenting objectives...")
        flush(stdout)
    end
    @timeit(timo, "Augment objectives", augment_objectives(ph_data))
    
    return ph_data
end

# function ef_add_variables(model::JuMP.Model,
#                           smod::M,
#                           s::ScenarioID,
#                           node::ScenarioNode,
#                           variable_dict::Dict{STAGE_ID, Vector{String}}
#                           )
    

#     return
# end

# function ef_copy_model(model::JuMP.Model,
#                        smod::M,
#                        s::ScenarioID,
#                        tree::ScenarioTree,
#                        variable_dict::Dict{STAGE_ID, Vector{String}},
#                        processed::Set{NodeID},
#                        ) where M <: JuMP.AbstractModel

#     stack = [root(tree)]
#     nodes = Set{NodeID}()

#     while !isempty(stack)
#         node = pop!(stack)

#         if s in scenario_bundle(node)

#             for c in node.children
#                 push!(stack, c)
#             end

#             if !(node.id in processed)
#                 ef_add_variables(model)
#                 # ef_add_constraints(model)
#                 # ef_add_objective(model, smod, s, tree)
                
#                 push!(nodes, node.id)
#             end
#         end
#     end

#     return nodes
# end

# function build_extensive_form(model::JuMP.Model,
#                               tree::ScenarioTree,
#                               variable_dict::Dict{STAGE_ID,Vector{String}},
#                               model_constructor::Function,
#                               constructor_args::Tuple;
#                               kwargs...)
#     processed = Set{NodeID}()
    
#     for s in scenarios(tree)
#         smod = model_constructor(_value(s), constructor_args...; kwargs...)

#         nodes = ef_copy_model(model, smod, s, tree, variable_dict, processed)

#         union!(processed, nodes)
#     end

#     return model
# end
