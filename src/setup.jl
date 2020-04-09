
function assign_scenarios_to_procs(scen_tree::ScenarioTree)::Dict{ScenarioID,Int}
    sp_map = Dict{ScenarioID, Int}()

    nprocs = Distributed.nworkers()
    wrks = workers()
    for (k,s) in enumerate(scenarios(scen_tree))
        sp_map[s] = wrks[(k-1) % nprocs + 1]
    end

    return sp_map
end

function augment_objectives(phd::PHData)::Nothing

    r = phd.r
    @sync for (scid, sinfo) in pairs(phd.scenario_map)
        subproblem = sinfo.subproblem
        vars = collect(keys(sinfo.branch_vars))
        @spawnat(sinfo.proc, add_ph_objective_terms(fetch(subproblem), vars, r))
    end

    return
end

function _create_model(scid::ScenarioID,
                       model_constructor::Function,
                       model_constructor_args::Tuple,
                       subtype::Type{S};
                       kwargs...
                       )::S where {S <: AbstractSubproblem}

    model = model_constructor(scid,
                              model_constructor_args...;
                              kwargs...)

    if typeof(model) != subtype
        @error("Model constructor function produced model of type " *
               "$(typeof(model)). " *
               "Expected model of type $(subtype). " *
               "Undefined behavior will probably result.")
    end

    return model
end
    

function create_models(scen_tree::ScenarioTree,
                       model_constructor::Function,
                       model_constructor_args::Tuple,
                       scen_proc_map::Dict{ScenarioID, Int},
                       sub_type::Type{S};
                       kwargs...
                       )::Dict{ScenarioID,Future} where {S <: AbstractSubproblem}

    submodels = Dict{ScenarioID,Future}()

    @sync for s in scenarios(scen_tree)
        proc = scen_proc_map[s]
        submodels[s] = @spawnat(proc,
                                _create_model(s,
                                              model_constructor,
                                              model_constructor_args,
                                              sub_type;
                                              kwargs...
                                              )
                                )
    end

    return submodels

end

function collect_variable_info(scen_tree::ScenarioTree,
                               scen_proc_map::Dict{ScenarioID, Int},
                               submodels::Dict{ScenarioID, Future},
                               )

    var_map = Dict{ScenarioID, Dict{VariableID, VariableInfo}}()
    var_report = Dict{ScenarioID, Future}()

    @sync for s in scenarios(scen_tree)
        proc = scen_proc_map[s]
        model = submodels[s]
        var_report[s] = @spawnat(proc, report_variable_info(fetch(model), scen_tree))
    end

    for s in scenarios(scen_tree)
        var_dict = Dict{VariableID, VariableInfo}()

        vdict = fetch(var_report[s])
        # TODO: Check for remote exception here
        for (vid, name) in pairs(vdict)
            nid = id(node(scen_tree, s, vid.stage))
            var_dict[vid] = VariableInfo(name, nid)
        end

        var_map[s] = var_dict
    end

    return var_map
end

function build_submodels(scen_tree::ScenarioTree,
                         model_constructor::Function,
                         model_constructor_args::Tuple,
                         sub_type::Type{S},
                         timo::TimerOutputs.TimerOutput;
                         kwargs...
                         ) where {S <: AbstractSubproblem}

    # Assign each subproblem to a particular juila process
    scen_proc_map = assign_scenarios_to_procs(scen_tree)

    # Construct the models
    submodels = @timeit(timo, "Create models",
                        create_models(scen_tree,
                                      model_constructor,
                                      model_constructor_args,
                                      scen_proc_map,
                                      sub_type;
                                      kwargs...)
                        )

    # Store variable references and other info
    var_map = @timeit(timo, "Collect variables",
                      collect_variable_info(scen_tree,
                                            scen_proc_map,
                                            submodels)
                      )

    return (submodels, scen_proc_map, var_map)
end

function initialize(scen_tree::ScenarioTree,
                    model_constructor::Function,
                    r::R,
                    sub_type::Type{S},
                    timo::TimerOutputs.TimerOutput,
                    report::Int,
                    constructor_args::Tuple,;
                    kwargs...
                    )::PHData where {S <: AbstractSubproblem,
                                     R <: Real}

    if report > 0
        println("...building submodels...")
        flush(stdout)
    end

    (submodels, scen_proc_map, var_map
     ) = @timeit(timo, "Submodel construction",
                 build_submodels(scen_tree,
                                 model_constructor,
                                 constructor_args,
                                 S,
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

    if report > 0
        println("...computing starting values...")
        flush(stdout)
    end
    @timeit(timo, "Compute start values", solve_subproblems(ph_data))

    if report > 0
        println("...augmenting objectives...")
        flush(stdout)
    end
    @timeit(timo, "Augment objectives", augment_objectives(ph_data))
    
    return ph_data
end

function build_extensive_form(optimizer::Function,
                              tree::ScenarioTree,
                              model_constructor::Function,
                              constructor_args::Tuple,
                              sub_type::Type{S};
                              kwargs...
                              )::JuMP.Model where {S <: AbstractSubproblem}

    model = JuMP.Model(optimizer)
    JuMP.set_objective_sense(model, MOI.MIN_SENSE)
    JuMP.set_objective_function(model, zero(JuMP.QuadExpr))

    # Below for mapping subproblem variables onto existing extensive form variables
    node_var_map = ef_node_dict_constructor(sub_type)

    for s in scenarios(tree)

        smod = model_constructor(s, constructor_args...; kwargs...)

        snode_var_map = ef_copy_model(model, smod, s, tree, node_var_map)

        @assert(isempty(intersect(keys(node_var_map), keys(snode_var_map))))
        merge!(node_var_map, snode_var_map)
    end

    return model
end
