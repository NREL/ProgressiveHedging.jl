function create_models(scen_tree::ScenarioTree,
                       model_constructor::Function,
                       model_constructor_args::Tuple,
                       scen_proc_map::Dict{ScenarioID, Int},
                       optimizer_factory::JuMP.OptimizerFactory,
                       model_type::Type{M};
                       kwargs...
                       ) where {M <: JuMP.AbstractModel}

    submodels = Dict{ScenarioID,Future}()

    @sync for s in scenarios(scen_tree)
        proc = scen_proc_map[s]
        sint = _value(s)
        submodels[s] = @spawnat(proc,
                                model_constructor(sint,
                                                  M(optimizer_factory),
                                                  model_constructor_args...;
                                                  kwargs...
                                                  )
                                )
    end

    return submodels

end

function collect_variable_refs(scen_tree::ScenarioTree,
                               scen_proc_map::Dict{ScenarioID, Int},
                               submodels::Dict{ScenarioID, Future},
                               variable_dict::Dict{SCENARIO_ID,Vector{String}},
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
                         variable_dict::Dict{SCENARIO_ID,Vector{String}},
                         optimizer_factory::JuMP.OptimizerFactory,
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
                                      optimizer_factory,
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

function initialize(scen_tree::ScenarioTree,
                    model_constructor::Function,
                    variable_dict::Dict{SCENARIO_ID,Vector{String}},
                    r::R,
                    optimizer_factory::JuMP.OptimizerFactory,
                    model_type::Type{M},
                    timo::TimerOutputs.TimerOutput,
                    report::Bool,
                    constructor_args::Tuple;
                    kwargs...
                    )::PHData where {S <: AbstractString,
                                     R <: Real,
                                     M <: JuMP.AbstractModel}

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
                                 optimizer_factory,
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
