
function build_scenario_tree(root_model::StructJuMP.StructuredModel)::ScenarioTree
    
    scen_tree = ScenarioTree(root_model)
    
    sj_models = [tuple(root_model.children[id], root_model.probability[id])
                 for id in sort!(collect(keys(root_model.children)))]
    
    while !isempty(sj_models)
        (sjm, prob) = popfirst!(sj_models)

        sjm_children = StructJuMP.getchildren(sjm)
        for id in sort!(collect(keys(sjm_children)))
            mod = sjm_children[id]
            # Assumes a Markov structure. This seems to be required by
            # the scenario structure induced by StructJuMP.
            push!(sj_models, tuple(mod, prob * sjm.probability[id]))
        end

        node = _add_node(scen_tree, sjm)

        if isempty(sjm_children)
            s = _create_scenario(scen_tree, sjm, prob)
        end
    end

    if abs(sum(values(scen_tree.prob_map)) - 1.0) > 1e-10
        @warn("Probabilities of all scenarios do not sum to 1 but to " *
              string(sum(values(scen_tree.prob_map))))
    end

    return scen_tree
end

function add_variables_extensive(model::Future,
                                 var_map::Dict{ScenarioID,
                                               Dict{VariableID, VariableInfo}},
                                 scen_tree::ScenarioTree,
                                 var_translator::Dict{NodeID,Dict{Int,Index}},
                                 sj_model::StructJuMP.StructuredModel,
                                 last_used::Index)::typeof(DUMMY_SCENARIO_ID)
    idx = last_used
    scid = DUMMY_SCENARIO_ID
    if !haskey(var_map, scid)
        var_map[scid] = Dict{VariableID, VariableInfo}()
    end

    for (id, var) in sj_model.variables
        vi = var.info
        # info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
        #                          vi.has_ub, vi.upper_bound,
        #                          vi.has_fix, vi.fixed_value,
        #                          vi.has_start, vi.start,
        #                          vi.binary, vi.integer)

        # Some solvers currently have issues with starting values,
        # especially when only some have starting values set as
        # seems to be the case when using PowerSimulations models
        info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
                                 vi.has_ub, vi.upper_bound,
                                 vi.has_fix, vi.fixed_value,
                                 false, vi.start,
                                 vi.binary, vi.integer)

        idx = _increment(idx)
        node = translate(scen_tree, sj_model)
        ph_vid = VariableID(node.stage, idx)

        name = sj_model.varnames[id]
        var_translator[node.id][id] = idx

        # Always local
        ref = @spawnat(1,
                       JuMP.add_variable(fetch(model),
                                         JuMP.build_variable(_error, info),
                                         name)
                       )
        var_map[scid][ph_vid] = VariableInfo(ref, name, node.id)
    end

    return scid
end

function build_extensive_form(root_model::StructJuMP.StructuredModel,
                              model::Future)::Future
    scen_tree = build_scenario_tree(root_model)

    sj_models = [root_model]
    probs = [1.0]
    obj = JuMP.GenericAffExpr{Float64, JuMP.variable_type(fetch(model))}()

    last_used = Index(0)
    var_map = Dict{ScenarioID, Dict{VariableID, VariableInfo}}()
    var_translator = Dict{NodeID, Dict{Int,Index}}()

    while !isempty(sj_models)
        sjm = popfirst!(sj_models)
        p = popfirst!(probs)

        for (id, cmod) in pairs(sjm.children)
            push!(sj_models, cmod)
            # Here's that Markov assumption again
            push!(probs, p * sjm.probability[id])
        end

        # Add variables
        node = translate(scen_tree, sjm)
        var_translator[node.id] = Dict{Int,Index}()
        scid = add_variables_extensive(model, var_map,
                                       scen_tree, var_translator,
                                       sjm, last_used)
        last_used = maximum(values(var_translator[node.id]))

        # Add constraints
        copy_constraints(model, sjm, scen_tree, var_translator, var_map,
                         scid, 1) # 1 here is the local process id

        # Add to objective function
        add_obj = convert_expression(model,
                                     sjm.objective_function,
                                     scen_tree, var_translator,
                                     scid, 1, # 1 here is the local process id
                                     var_map)
        obj += p * fetch(add_obj)
    end

    # Add objective function
    JuMP.set_objective(fetch(model), root_model.objective_sense, obj)

    return model
end

function create_submodels(scen_tree::ScenarioTree,
                          scen_proc_map::Dict{ScenarioID, Int},
                          opt_factory::JuMP.OptimizerFactory,
                          ::Type{M}
                          )::Dict{ScenarioID,Future} where {M <: JuMP.AbstractModel}

    submodels = Dict{ScenarioID, Future}()
    @sync for s in scenarios(scen_tree)
        submodels[s] = @spawnat(scen_proc_map[s],
                                M(opt_factory))
    end

    return submodels
end

function add_variables(submodels::Dict{ScenarioID, Future},
                       scen_proc_map::Dict{ScenarioID, Int},
                       var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}},
                       var_translator::Dict{NodeID, Dict{Int,Index}},
                       node::ScenarioNode,
                       sj_model::StructJuMP.StructuredModel)::Nothing

    vdict = Dict{Int,Index}()
    for id in sort!(collect(keys(sj_model.variables)))
        vi = sj_model.variables[id].info

        # info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
        #                          vi.has_ub, vi.upper_bound,
        #                          vi.has_fix, vi.fixed_value,
        #                          vi.has_start, vi.start,
        #                          vi.binary, vi.integer)

        # Some solvers currently have issues with starting values,
        # especially when only some have starting values set as
        # seems to be the case when using PowerSimulations models
        info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
                                 vi.has_ub, vi.upper_bound,
                                 vi.has_fix, vi.fixed_value,
                                 false, vi.start,
                                 vi.binary, vi.integer)
        name = sj_model.varnames[id]
        idx = next_index(node)
        vdict[id] = idx

        @sync for s in node.scenario_bundle
            if !haskey(var_map, s)
                var_map[s] = Dict{VariableID, VariableInfo}()
            end

            model = submodels[s]
            
            ref = @spawnat(scen_proc_map[s],
                           JuMP.add_variable(fetch(model),
                                             JuMP.build_variable(_error, info)))

            ph_vid = VariableID(node.stage, idx)
            var_map[s][ph_vid] = VariableInfo(ref, name, node.id)
        end
    end
    
    var_translator[node.id] = vdict
    
    return
end

function translate_variable_ref(sj_ref::StructJuMP.StructuredVariableRef,
                                scen_tree::ScenarioTree,
                                var_node_trans::Dict{NodeID,Dict{Int,Index}},
                                scen::ScenarioID,
                                var_map::Dict{ScenarioID,
                                              Dict{VariableID, VariableInfo}}
                                )
    node = translate(scen_tree, sj_ref.model)
    vtrans = var_node_trans[node.id]
    vid = VariableID(node.stage, vtrans[sj_ref.idx])
    return var_map[scen][vid].ref
end

function convert_expression(model::Future,
                            expr::JuMP.GenericAffExpr{Float64, StructJuMP.StructuredVariableRef},
                            scen_tree::ScenarioTree,
                            vtrans::Dict{NodeID,Dict{Int,Index}},
                            scen::ScenarioID,
                            proc::Int,
                            var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}}
                            )

    V = @spawnat(proc, JuMP.variable_type(fetch(model)))
    new_expr = @spawnat(proc, JuMP.GenericAffExpr{Float64, fetch(V)}())

    constant = JuMP.constant(expr)
    @spawnat(proc, JuMP.add_to_expression!(fetch(new_expr), constant))
    
    for (coef, var) in JuMP.linear_terms(expr)
        new_var = translate_variable_ref(var, scen_tree, vtrans, scen, var_map)
        @spawnat(proc,
                 JuMP.add_to_expression!(fetch(new_expr), coef, fetch(new_var)))
    end
    
    return new_expr
end

function convert_expression(model::Future,
                            expr::JuMP.GenericQuadExpr{Float64, StructJuMP.StructuredVariableRef},
                            scen_tree::ScenarioTree,
                            vtrans::Dict{NodeID,Dict{Int, Index}},
                            scen::ScenarioID,
                            proc::Int,
                            var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}}
                            )

    V = @spawnat(proc, JuMP.variable_type(fetch(model)))
    new_expr = @spawnat(proc, JuMP.GenericQuadExpr{Float64, fetch(V)}())

    new_aff_expr = convert_expression(model, expr.aff, scen_tree, vtrans,
                                      scen, proc, var_map)

    @spawnat(proc, JuMP.add_to_expression!(fetch(new_expr), fetch(new_aff_expr)))
    
    for (coef, var1, var2) in JuMP.quad_terms(expr)
        new_var1 = translate_variable_ref(var1, scen_tree, vtrans, scen, var_map)
        new_var2 = translate_variable_ref(var2, scen_tree, vtrans, scen, var_map)
        up = @spawnat(proc,
                      JuMP.UnorderedPair{fetch(V)}(fetch(new_var1),
                                                   fetch(new_var2)))
        
        zero_aff_expr = @spawnat(proc,
                                 zero(JuMP.GenericAffExpr{Float64, fetch(V)}))
        @spawnat(proc,
                 JuMP.add_to_expression!(fetch(new_expr),
                                         JuMP.GenericQuadExpr{Float64,fetch(V)}(
                                             fetch(zero_aff_expr),
                                             fetch(up) => coef)
                                         )
                 )
    end
    
    return new_expr
end

function convert_expression(model::Future,
                            expr::S,
                            scen_tree::ScenarioTree,
                            vtrans::Dict{NodeID,Dict{Int,Index}},
                            scen::ScenarioID,
                            proc::Int,
                            var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}}
                            ) where {V <: JuMP.AbstractVariableRef,
                                     S <: JuMP.AbstractJuMPScalar}
    @error("Unrecognized expression type: " * string(S))
    return nothing
end

function make_constraint(new_expr::Future, con::JuMP.ScalarConstraint, proc::Int
                         ) where S <: JuMP.AbstractJuMPScalar
    set = JuMP.moi_set(con)
    new_con = @spawnat(proc, JuMP.ScalarConstraint(fetch(new_expr), set))
    return new_con
end

function make_constraint(new_expr::Future, con::JuMP.VectorConstraint, proc::Int
                         ) where S <: JuMP.AbstractJuMPScalar
    set = JuMP.moi_set(con)
    shape = JuMP.shape(con)
    new_con = @spawnat(proc, JuMP.VectorConstraint(fetch(new_expr), set, shape))
    return new_con
end

function make_constraint(new_expr::Future, con::C, proc::Int) where {C <: JuMP.AbstractConstraint}
    @error "Unsupported constraint type: " * string(C)
    return nothing
end

function copy_constraints(model::Future, sj_model::StructJuMP.StructuredModel,
                          scen_tree::ScenarioTree,
                          var_translator::Dict{NodeID, Dict{Int,Index}},
                          var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}},
                          scen::ScenarioID,
                          proc::Int)

    for (id, con) in sj_model.constraints
        new_con_expr = convert_expression(model,
                                          JuMP.jump_function(con),
                                          scen_tree, var_translator,
                                          scen, proc, var_map)
        new_con = make_constraint(new_con_expr, con, proc)
        @spawnat(proc, JuMP.add_constraint(fetch(model), fetch(new_con)))
    end

    return
end

function add_constraints(submodels::Dict{ScenarioID, Future},
                         node::ScenarioNode,
                         sj_model::StructJuMP.StructuredModel,
                         scen_tree::ScenarioTree,
                         scen_proc_map::Dict{ScenarioID, Int},
                         var_translator::Dict{NodeID, Dict{Int, Index}},
                         var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}})

    @sync for s in node.scenario_bundle
        model = submodels[s]
        proc = scen_proc_map[s]
        copy_constraints(model, sj_model, scen_tree, var_translator,
                         var_map, s, proc)
    end

    return
end

function add_objectives(submodels::Dict{ScenarioID,Future},
                        node::ScenarioNode,
                        sj_model::StructJuMP.StructuredModel,
                        scen_tree::ScenarioTree,
                        scen_proc_map::Dict{ScenarioID, Int},
                        var_translator::Dict{NodeID, Dict{Int,Index}},
                        var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}})
    
    @sync for s in node.scenario_bundle
        model = submodels[s]
        proc = scen_proc_map[s]
        obj = @spawnat(proc, JuMP.objective_function(fetch(model)))
        add_expr = convert_expression(model,
                                      sj_model.objective_function,
                                      scen_tree,
                                      var_translator,
                                      s,
                                      proc,
                                      var_map)
        new_obj = @spawnat(proc, fetch(obj) + fetch(add_expr))
        @spawnat(proc,
                 JuMP.set_objective(fetch(model),
                                    sj_model.objective_sense,
                                    fetch(new_obj))
                 )
    end
    
    return
end

function add_attributes(submodels::Dict{ScenarioID, Future},
                        var_map::Dict{ScenarioID, Dict{VariableID, VariableInfo}},
                        sj_model::StructJuMP.StructuredModel,
                        node::ScenarioNode,
                        scen_tree::ScenarioTree,
                        scen_proc_map::Dict{ScenarioID, Int},
                        var_translator::Dict{NodeID, Dict{Int, Index}})

    add_variables(submodels, scen_proc_map, var_map,
                  var_translator, node, sj_model)
    add_constraints(submodels, node, sj_model, scen_tree, scen_proc_map,
                    var_translator, var_map)
    add_objectives(submodels, node, sj_model, scen_tree, scen_proc_map,
                   var_translator, var_map)

    return
end

function convert_to_submodels(root_model::StructJuMP.StructuredModel,
                              opt_factory::JuMP.OptimizerFactory,
                              scen_tree::ScenarioTree,
                              ::Type{M}
                              ) where {M <: JuMP.AbstractModel}

    scen_proc_map = assign_scenarios_to_procs(scen_tree)
    submodels = create_submodels(scen_tree, scen_proc_map, opt_factory, M)
    
    var_map = Dict{ScenarioID, Dict{VariableID,VariableInfo}}()
    for scid in scenarios(scen_tree)
        var_map[scid] = Dict{VariableID, VariableInfo}()
    end

    var_translator = Dict{NodeID, Dict{Int,Index}}()

    sj_models = [root_model]
    while !isempty(sj_models)
        sjm = popfirst!(sj_models)
        
        append!(sj_models, values(StructJuMP.getchildren(sjm)))
        
        add_attributes(submodels, var_map,
                       sjm, translate(scen_tree, sjm),
                       scen_tree, scen_proc_map,
                       var_translator)
    end

    return (submodels, scen_proc_map, var_map)
end

function initialize(root_model::StructJuMP.StructuredModel,
                    r::R,
                    optimizer_factory::JuMP.OptimizerFactory,
                    ::Type{M},
                    timo::TimerOutputs.TimerOutput,
                    report::Bool
                    )::PHData where {R <: Real, M <: JuMP.AbstractModel}

    if report
        println("Building scenario tree...")
        flush(stdout)
    end

    scen_tree = @timeit(timo, "Build scenario tree",
                        build_scenario_tree(root_model))

    if report
        println("Constructing submodels...")
        flush(stdout)
    end

    (submodels, scen_proc_map, var_map
     ) = @timeit(timo, "Submodel construction",
                 convert_to_submodels(root_model,
                                      optimizer_factory,
                                      scen_tree,
                                      M
                                      )
                 )

    ph_data = PHData(r, scen_tree, scen_proc_map, scen_tree.prob_map,
                     submodels, var_map, timo)

    if report
        println("...computing start points...")
        flush(stdout)
    end
    @timeit(timo, "Compute start values", solve_subproblems(ph_data))

    if report
        println("...initializing PH variables...")
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
