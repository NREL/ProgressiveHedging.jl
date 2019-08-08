function build_submodels(scen_tree::ScenarioTree, model_constructor::Function,
                         variable_dict::Dict{SCENARIO_ID,Vector{String}},
                         optimizer_factory::JuMP.OptimizerFactory,
                         model_type::Type{M}
                         ) where {M <: JuMP.AbstractModel}

    submodels = Dict{ScenarioID,Future}()
    scen_proc_map = assign_scenarios_to_procs(scen_tree)
    var_map = Dict{VariableID,VariableInfo}()

    # Construct the models

    # # The below stuff is so model construction executes serially on processes
    # # when assigned more than one scenario.  This means the user can do things
    # # like read files and not have it get messed up.

    # proc_scen_map = Dict{Int, Set{ScenarioID}}()
    # for (s,p) in pairs(scen_proc_map)
    #     if p in keys(proc_scen_map)
    #         push!(proc_scen_map[p], s)
    #     else
    #         proc_scen_map[p] = Set{ScenarioID}([s])
    #     end
    # end

    # scens = copy(scenarios(scen_tree))
    # while !isempty(scens)
    #     @sync for (p, scen_set) in pairs(proc_scen_map)
    #         s = pop!(scen_set)
    #         sint = _value(s)
    #         delete!(scens, s)
    #         submodels[s] = @spawnat(p, model_constructor(sint, M(optimizer_factory)))
    #     end
    # end
    
    @sync for s in scenarios(scen_tree)
        proc = scen_proc_map[s]
        sint = _value(s)
        submodels[s] = @spawnat(proc,
                                model_constructor(sint,
                                                  M(optimizer_factory)))
    end

    @sync for (nid, node) in pairs(scen_tree.tree_map)

        @assert(_value(node.stage) in keys(variable_dict))

        for var_name in variable_dict[_value(node.stage)]
            idx = next_index(node)

            for s in node.scenario_bundle
                vid = VariableID(s, node.stage, idx)
                proc = scen_proc_map[s]
                model = submodels[s]

                ref = @spawnat(proc, JuMP.variable_by_name(fetch(model), var_name))
                var_map[vid] = VariableInfo(ref, var_name)
            end
        end
    end

    return (submodels, scen_proc_map, var_map)
end

function initialize(scen_tree::ScenarioTree,
                    model_constructor::Function,
                    variable_dict::Dict{SCENARIO_ID,Vector{String}},
                    r::R,
                    optimizer_factory::JuMP.OptimizerFactory,
                    model_type::Type{M}
                    )::PHData where {S <: AbstractString,
                                     R <: Real,
                                     M <: JuMP.AbstractModel}

    println("...setting up submodels...")
    (submodels, scen_proc_map, var_map
     ) = build_submodels(scen_tree, model_constructor, variable_dict,
                         optimizer_factory, M)

    ph_data = PHData(r, scen_tree, scen_proc_map, scen_tree.prob_map,
                     submodels, var_map)

    println("...computing start points...")
    compute_start_points(ph_data)
    println("...finishing setup...")
    compute_and_save_xhat(ph_data)
    compute_and_save_w(ph_data)
    augment_objectives(ph_data)
    
    return ph_data
end

