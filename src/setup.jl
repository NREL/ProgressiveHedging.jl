
function _error(astring::String)
    return
end

function build_scenario_tree(root_model::StructJuMP.StructuredModel)
    
    scen_tree = ScenarioTree(root_model)
    
    sj_models = [tuple(root_model.children[id], 2, root_model.probability[id])
                 for id in sort!(collect(keys(root_model.children)))]
    probs = Dict{ScenarioID, Float64}()
    
    while !isempty(sj_models)
        (sjm, stage, prob) = popfirst!(sj_models)

        sjm_children = StructJuMP.getchildren(sjm)
        for id in sort!(collect(keys(sjm_children)))
            mod = sjm_children[id]
            # Assumes a Markov structure. This seems to be required by
            # the scenario structure induced by StructJuMP.
            push!(sj_models, tuple(mod, stage+1, prob * sjm.probability[id]))
        end

        node = add_node(scen_tree, sjm, StageID(stage))

        if isempty(sjm_children)
            s = add_scenario(scen_tree, sjm)
            probs[s] = prob
        end
    end

    if abs(sum(values(probs)) - 1.0) > 1e-10
        @warn("Probabilities of all scenarios do not sum to 1 but to " *
              string(sum(values(probs))))
    end

    return (scen_tree, probs)
end

function add_variables_extensive(model::M,
                                 var_map::Dict{VariableID, VariableInfo{K}},
                                 name_map::Dict{VariableID, String},
                                 scen_tree::ScenarioTree,
                                 var_translator::Dict{NodeID,Dict{Int,Index}},
                                 sj_model::StructJuMP.StructuredModel,
                                 last_used::Index
                                 ) where {M <: JuMP.AbstractModel,
                                          K <: JuMP.AbstractVariableRef}
    idx = last_used
    scid = DUMMY_SCENARIO_ID

    for (id, var) in sj_model.variables
        vi = var.info
        info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
                                 vi.has_ub, vi.upper_bound,
                                 vi.has_fix, vi.fixed_value,
                                 vi.has_start, vi.start,
                                 vi.binary, vi.integer)

        idx = _increment(idx)
        node = translate(scen_tree, sj_model)
        ph_vid = VariableID(scid, node.stage, idx)

        name = sj_model.varnames[id]
        var_translator[node.id][id] = idx
        name_map[ph_vid] = name

        ref = JuMP.add_variable(model, JuMP.build_variable(_error, info), name)
        var_map[ph_vid] = VariableInfo(ref)
    end

    return scid
end

function add_variables(submodels::Dict{ScenarioID, M},
                       var_map::Dict{VariableID, VariableInfo{K}},
                       name_map::Dict{VariableID, String},
                       var_translator::Dict{NodeID, Dict{Int,Index}},
                       node::ScenarioNode,
                       sj_model::StructJuMP.StructuredModel
                       ) where {M <: JuMP.AbstractModel,
                                K <: JuMP.AbstractVariableRef}
    vdict = Dict{Int,Index}()
    for id in sort!(collect(keys(sj_model.variables)))
        vi = sj_model.variables[id].info
        info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
                                 vi.has_ub, vi.upper_bound,
                                 vi.has_fix, vi.fixed_value,
                                 vi.has_start, vi.start,
                                 vi.binary, vi.integer)
        name = sj_model.varnames[id]
        idx = next_index(node)
        vdict[id] = idx

        for s in node.scenario_bundle
            model = submodels[s]
            ph_vid = VariableID(s, node.stage, idx)
            
            ref = JuMP.add_variable(model, JuMP.build_variable(_error, info), name)
            var_map[ph_vid] = VariableInfo(ref)
            name_map[ph_vid] = name
        end
    end
    
    var_translator[node.id] = vdict

    if node.num_variables != length(node.variable_indices)
        @error("Expected $node.nvar variables but got " *
               length(node.variable_indices))
    end
    
    return
end

function translate_variable_ref(sj_ref::StructJuMP.StructuredVariableRef,
                                scen_tree::ScenarioTree,
                                var_node_trans::Dict{NodeID,Dict{Int,Index}},
                                scen::ScenarioID,
                                var_map::Dict{VariableID, VariableInfo{V}}
                                ) where {V <: JuMP.AbstractVariableRef}
    node = translate(scen_tree, sj_ref.model)
    vtrans = var_node_trans[node.id]
    vid = VariableID(scen, node.stage, vtrans[sj_ref.idx])
    return var_map[vid].ref
end

function convert_expression(::Type{V},
                            expr::JuMP.GenericAffExpr{Float64, StructJuMP.StructuredVariableRef},
                            scen_tree::ScenarioTree,
                            vtrans::Dict{NodeID,Dict{Int,Index}},
                            scen::ScenarioID,
                            var_map::Dict{VariableID,VariableInfo{V}}
                            ) where {V <: JuMP.AbstractVariableRef}
    
    new_expr = JuMP.GenericAffExpr{Float64, V}()
    
    new_expr += JuMP.constant(expr)
    
    for (coef, var) in JuMP.linear_terms(expr)
        new_var = translate_variable_ref(var, scen_tree, vtrans, scen, var_map)
        new_expr += JuMP.GenericAffExpr{Float64, V}(0.0, new_var => coef)
    end
    
    return new_expr
end

function convert_expression(::Type{V},
                            expr::JuMP.GenericQuadExpr{Float64, StructJuMP.StructuredVariableRef},
                            scen_tree::ScenarioTree,
                            vtrans::Dict{NodeID,Dict{Int,Index}},
                            scen::ScenarioID,
                            var_map::Dict{VariableID,VariableInfo{V}}
                            ) where {V <: JuMP.AbstractVariableRef}
    
    new_expr = JuMP.GenericQuadExpr{Float64, V}()
    
    new_expr += convert_expression(V, expr.aff, scen_tree, vtrans, scen, var_map)
    
    for (coef, var1, var2) in JuMP.quad_terms(expr)
        new_var1 = translate_variable_ref(var1, scen_tree, vtrans, scen, var_map)
        new_var2 = translate_variable_ref(var2, scen_tree, vtrans, scen, var_map)
        up = JuMP.UnorderedPair{V}(new_var1, new_var2)
        
        zero_aff_expr = zero(JuMP.GenericAffExpr{Float64, V})
        new_expr += JuMP.GenericQuadExpr{Float64, V}(zero_aff_expr, up => coef)
    end
    
    return new_expr
end

function convert_expression(::Type{V},
                            expr::S,
                            scen_tree::ScenarioTree,
                            vtrans::Dict{NodeID,Dict{Int,Index}},
                            scen::ScenarioID,
                            var_map::Dict{VariableID,VariableInfo{V}}
                            ) where {V <: JuMP.AbstractVariableRef,
                                     S <: JuMP.AbstractJuMPScalar}
    @error("Unrecognized expression type: " * string(S))
    return nothing
end

function make_constraint(new_expr::S, con::JuMP.ScalarConstraint
                         ) where S <: JuMP.AbstractJuMPScalar
    new_con = JuMP.ScalarConstraint(new_expr, JuMP.moi_set(con))
    return new_con
end

function make_constraint(new_expr::S, con::JuMP.VectorConstraint
                         ) where S <: JuMP.AbstractJuMPScalar
    new_con = JuMP.VectorConstraint(new_expr, JuMP.moi_set(con), JuMP.shape(con))
    return new_con
end

function make_constraint(new_expr::S, con::C) where {S <: JuMP.AbstractJuMPScalar, C <: JuMP.AbstractConstraint}
    @error "Unsupported constraint type: " * string(C)
    return nothing
end

function copy_constraints(model::M, sj_model::StructJuMP.StructuredModel,
                          scen_tree::ScenarioTree,
                          var_translator::Dict{NodeID, Dict{Int,Index}},
                          scen::ScenarioID,
                          var_map::Dict{VariableID, VariableInfo{V}}
                          ) where {M <: JuMP.AbstractModel,
                                   V <: JuMP.AbstractVariableRef}
    for (id, con) in sj_model.constraints
        new_con_expr = convert_expression(JuMP.variable_type(model),
                                          JuMP.jump_function(con),
                                          scen_tree, var_translator,
                                          scen, var_map)
        new_con = make_constraint(new_con_expr, con)
        JuMP.add_constraint(model, new_con, sj_model.connames[id])
    end
    return
end

function add_constraints(submodels::Dict{ScenarioID,M},
                         node::ScenarioNode,
                         sj_model::StructJuMP.StructuredModel,
                         scen_tree::ScenarioTree,
                         var_translator::Dict{NodeID, Dict{Int,Index}},
                         var_map::Dict{VariableID, VariableInfo{V}}
                         ) where {M <: JuMP.AbstractModel,
                                  V <: JuMP.AbstractVariableRef}
    for s in node.scenario_bundle
        model = submodels[s]
        copy_constraints(model, sj_model, scen_tree, var_translator,
                         s, var_map)
    end

    return
end

function add_objectives(submodels::Dict{ScenarioID,M},
                        node::ScenarioNode,
                        sj_model::StructJuMP.StructuredModel,
                        scen_tree::ScenarioTree,
                        var_translator::Dict{NodeID, Dict{Int,Index}},
                        var_map::Dict{VariableID, VariableInfo{V}}
                        ) where {M <: JuMP.AbstractModel,
                                 V <: JuMP.AbstractVariableRef}
    
    for s in node.scenario_bundle
        model = submodels[s]
        obj = JuMP.objective_function(model)
        obj += convert_expression(JuMP.variable_type(model),
                                  sj_model.objective_function,
                                  scen_tree,
                                  var_translator,
                                  s, var_map)
        JuMP.set_objective(model, sj_model.objective_sense, obj)
    end
    
    return
end

function add_attributes(submodels::Dict{ScenarioID, M},
                        var_map::Dict{VariableID, VariableInfo{K}},
                        name_map::Dict{VariableID, String},
                        sj_model::StructJuMP.StructuredModel,
                        node::ScenarioNode,
                        scen_tree::ScenarioTree,
                        var_translator::Dict{NodeID, Dict{Int, Index}}
                        ) where {M <: JuMP.AbstractModel,
                                 K <: JuMP.AbstractVariableRef}
    add_variables(submodels, var_map, name_map, var_translator,
                  node, sj_model)
    add_constraints(submodels, node, sj_model, scen_tree,
                    var_translator, var_map)
    add_objectives(submodels, node, sj_model, scen_tree,
                   var_translator, var_map)
    return
end

function convert_to_submodels(root_model::StructJuMP.StructuredModel,
                              opt_factory::JuMP.OptimizerFactory,
                              scen_tree::ScenarioTree,
                              ::Type{M}
                              ) where {M <: JuMP.AbstractModel}
    
    submodels = Dict{ScenarioID, M}(s => M(opt_factory)
                                    for s in scenarios(scen_tree))
    V = JuMP.variable_type(first(submodels)[2])
    var_map = Dict{VariableID, VariableInfo{V}}()
    name_map = Dict{VariableID, String}()
    var_translator = Dict{NodeID, Dict{Int,Index}}()

    sj_models = [root_model]
    while !isempty(sj_models)
        sjm = popfirst!(sj_models)
        
        append!(sj_models, values(StructJuMP.getchildren(sjm)))
        
        add_attributes(submodels, var_map, name_map,
                       sjm, translate(scen_tree, sjm),
                       scen_tree, var_translator)
    end

    return (submodels, var_map, name_map)
end

function compute_start_points(phd::PHData)
    
    # This is parallelizable
    for (scen, model) in pairs(phd.submodels)
        JuMP.optimize!(model)

        # MOI refers to the MathOptInterface package. Apparently this is made
        # accessible by JuMP since it is not imported here
        sts = JuMP.termination_status(model)
        if sts != MOI.OPTIMAL && sts != MOI.LOCALLY_SOLVED
            @error("Initialization solve for scenario $scen returned $sts.")
        end
    end
    
    return
end

function augment_objectives(phd::PHData)
    V = JuMP.variable_type(first(phd.submodels)[2])
    
    for (nid, node) in pairs(phd.scenario_tree.tree_map)

        for s in node.scenario_bundle

            model = phd.submodels[s]
            obj = JuMP.objective_function(model)

            for i in node.variable_indices

                var_id = VariableID(s, node.stage, i)
                xhat_id = XhatID(nid, i)
                var_ref = phd.variable_map[var_id].ref
                
                w_ref = V(model)
                JuMP.set_name(w_ref, "W_" * JuMP.name(var_ref))
                phd.W_ref[var_id] = w_ref
                
                xhat_ref = V(model)
                JuMP.set_name(xhat_ref, "Xhat_" * JuMP.name(var_ref))
                if !(xhat_id in keys(phd.Xhat_ref))
                    phd.Xhat_ref[xhat_id] = Set{V}()
                end
                push!(phd.Xhat_ref[xhat_id], xhat_ref)

                obj += var_ref * w_ref + 0.5 * phd.r * (var_ref - xhat_ref)^2
            end

            JuMP.set_objective_function(model, obj)
        end
    end
    
    return
end

function initialize(root_model::StructJuMP.StructuredModel, r::N,
                    optimizer_factory::JuMP.OptimizerFactory, ::Type{M}
                    ) where {N <: Number, M <: JuMP.AbstractModel}
    (scen_tree, probs) = build_scenario_tree(root_model)
    (submodels, var_map, name_map) = convert_to_submodels(root_model,
                                                          optimizer_factory,
                                                          scen_tree,
                                                          M)
    ph_data = PHData(r, scen_tree, probs, submodels, var_map, name_map)
    compute_start_points(ph_data)
    compute_and_save_xhat(ph_data)
    augment_objectives(ph_data)
    return ph_data
end
