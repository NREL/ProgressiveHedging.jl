
function _error(astring::String)
    return
end

function fill_scenario_bundles(node_map::Dict{StructJuMP.StructuredModel,
                                              ModelInfo{K}},
                               leaves::Dict{K,StructJuMP.StructuredModel}
                               ) where {K}
    for (scen,leaf) in pairs(leaves)
        m = leaf
        while m != nothing
            push!(node_map[m].scen_bundle, scen)
            m = StructJuMP.getparent(m)
        end
    end
end

function extract_structure_recursive(model::StructJuMP.StructuredModel,
                                     node_map::Dict{StructJuMP.StructuredModel,
                                                    ModelInfo{K}},
                                     depth::Int
                                     ) where {K}
    child_probs = Dict{eltype(keys(model.children)), Float64}()
    leaves = Dict{eltype(keys(model.children)), StructJuMP.StructuredModel}()
    num_scens = 0

    if model.parent == nothing
        node_map[model] = ModelInfo("0", depth, Set{K}())
    end
    
    for key in keys(model.children)
        
        node_map[model.children[key]] = ModelInfo(node_map[model].id * "." * string(key), depth+1, Set{K}())
        (nscen, probs, leafs) = extract_structure_recursive(model.children[key],
                                                            node_map, depth+1)
        num_scens += nscen
        
        if isempty(probs)
            child_probs[key] = model.probability[key]
            leaves[key] = model.children[key]
        else
            leaves = merge!(leaves, leafs)
            for k in keys(probs)
                if k in keys(child_probs)
                    @error ("Leaves of scenario tree must have unique identifiers:"
                            * " $k was repeated")
                else
                    # Assumes a Markov structure. This seems to be required by
                    # the scenario structure induced by StructJuMP.
                    child_probs[k] = probs[k] * model.probability[key]
                end
            end
        end
        
    end
    
    retval = (isempty(child_probs) ? 1 : num_scens,
              child_probs,
              leaves,
              node_map)
    
    return retval
end

function extract_structure(root_model::StructJuMP.StructuredModel)
    node_map = Dict{StructJuMP.StructuredModel,
                    ModelInfo{eltype(keys(root_model.children))}}()
    
    (nscen, probs, leaves, node_map) = extract_structure_recursive(root_model,
                                                                   node_map, 1)
    fill_scenario_bundles(node_map, leaves)
    scen_set = Set(keys(probs))

    if abs(sum(values(probs)) - 1.0) > 1e-12
        @warn "Probability of all scenarios sums to " * string(sum(values(probs)))
    end

    key_type = eltype(keys(root_model.children))
    model_dict = Dict{key_type, JuMP.Model}()
    phii = PHInitInfo{key_type}(scen_set, leaves, node_map)
    
    return (phii, probs)
end

function name_variables(model::StructJuMP.StructuredModel)

    vdict=Dict{String, StructJuMP.StructuredVariableRef}()
    
    for id in keys(model.variables)
        name = model.varnames[id]
        vdict[name] = StructJuMP.StructuredVariableRef(model,id)
    end
    
    return vdict
end

function map_new_variables(variable_map::Dict{String, VariableInfo{K}},
                           sj_model::StructJuMP.StructuredModel,
                           new_vars::Dict{String, StructJuMP.StructuredVariableRef},
                           model_info::ModelInfo{K}
                           ) where {K, M <: JuMP.AbstractModel}
    for name in keys(new_vars)
        if name in keys(variable_map)
            vi = variable_map[name]
            if vi.stage != model_info.stage
                @error("Variable stage mismatch: " * name
                       * " in stages $vi.stage and $model_info.stage")
            end
            if vi.scenario_bundle != model_info.scen_bundle
                @error("Variable scenario bundle mismatch: " * name
                       * " in " * string(vi.scenario_bundle) * " and "
                       * string(model_info.scen_bundle))
            end
            if vi.sj_model != sj_model
                @error("Variable StructJuMP model mismatch: " * name
                       * " belongs to multiple StructJuMP models")
            end
        else
            variable_map[name] = VariableInfo(model_info.stage,
                                              model_info.scen_bundle,
                                              sj_model)
        end
    end
end

function collect_variables(variable_map::Dict{String, VariableInfo{K}},
                           node_map::Dict{StructJuMP.StructuredModel, ModelInfo{K}},
                           leaf_model::StructJuMP.StructuredModel
                           ) where {M <: JuMP.AbstractModel, K}
    
    vars = Dict{String, StructJuMP.StructuredVariableRef}()
    m = leaf_model
    
    while m != nothing
        new_vars = name_variables(m)
        
        if !isempty(intersect(vars, new_vars))
            @error("Common variable names in different stages is not supported: "
                   * string(intersect(vars, new_vars)))
            break
        end
        
        map_new_variables(variable_map, m, new_vars, node_map[m])
        merge!(vars, new_vars)
        m = StructJuMP.getparent(m)
    end
    
    return vars
end

function add_variables(model::M, variable_map::Dict{String, VariableInfo{K}},
                       node_map::Dict{StructJuMP.StructuredModel, ModelInfo{K}},
                       leaf_model::StructJuMP.StructuredModel
                       ) where {M <: JuMP.AbstractModel, K}
    vars = collect_variables(variable_map, node_map, leaf_model)
    for (name, ref) in pairs(vars)
        vi = ref.model.variables[ref.idx].info
        info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
                                 vi.has_ub, vi.upper_bound,
                                 vi.has_fix, vi.fixed_value,
                                 vi.has_start, vi.start,
                                 vi.binary, vi.integer)
        JuMP.add_variable(model, JuMP.build_variable(_error, info), name)
    end
    return
end

function get_new_var(model::M, var::StructJuMP.StructuredVariableRef) where M <: JuMP.AbstractModel
    name = var.model.varnames[var.idx]
    return JuMP.variable_by_name(model, name)
end

function convert_expression(model::M, expr::JuMP.GenericAffExpr{Float64, StructJuMP.StructuredVariableRef}) where {M <: JuMP.AbstractModel}
    
    V = JuMP.variable_type(model)
    new_expr = JuMP.GenericAffExpr{Float64, V}()
    
    new_expr += JuMP.constant(expr)
    
    for (coef, var) in JuMP.linear_terms(expr)
        new_var = get_new_var(model, var)
        new_expr += JuMP.GenericAffExpr{Float64, V}(0.0, new_var => coef)
    end
    
    return new_expr
end

function convert_expression(model::M, expr::JuMP.GenericQuadExpr{Float64, StructJuMP.StructuredVariableRef}) where {M <: JuMP.AbstractModel}
    
    V = JuMP.variable_type(model)
    new_expr = JuMP.GenericQuadExpr{Float64, V}()
    
    new_expr += convert_expression(model, expr.aff)
    
    for (coef, var1, var2) in JuMP.quad_terms(expr)
        new_var1 = get_new_var(model, var1)
        new_var2 = get_new_var(model, var2)
        up = JuMP.UnorderedPair{V}(new_var1, new_var2)
        zero_aff_expr = zero(JuMP.GenericAffExpr{Float64, V})
        new_expr += JuMP.GenericQuadExpr{Float64, V}(zero_aff_expr, up => coef)
    end
    
    return new_expr
end

function convert_expression(model::M, expr::S) where {M <: JuMP.AbstractModel, S <: JuMP.AbstractJuMPScalar}
    @error("Unrecognized expression type: " * string(S))
    return nothing
end

function collect_objectives(model::M, leaf_model::StructJuMP.StructuredModel) where {M <: JuMP.AbstractModel}
    V = JuMP.variable_type(model)
    obj = JuMP.GenericAffExpr{Float64, V}()
    m = leaf_model
    while m != nothing
        obj += convert_expression(model, m.objective_function)
        m = StructJuMP.getparent(m)
    end
    return obj
end

function add_objective(model::M, root_model::StructJuMP.StructuredModel,
                       leaf_model::StructJuMP.StructuredModel
                       ) where {M <: JuMP.AbstractModel}
    obj = collect_objectives(model, leaf_model)
    JuMP.set_objective(model, root_model.objective_sense, obj)
    return
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

function copy_constraints(model::M, sj_model::StructJuMP.StructuredModel
                          ) where {M <: JuMP.AbstractModel}
    for (id, con) in sj_model.constraints
        new_con_expr = convert_expression(model, JuMP.jump_function(con))
        new_con = make_constraint(new_con_expr, con)
        JuMP.add_constraint(model, new_con, sj_model.connames[id])
    end
    return
end

function add_constraints(model::M, leaf_model::StructJuMP.StructuredModel
                         ) where {M <: JuMP.AbstractModel}
    m = leaf_model
    while m != nothing
        copy_constraints(model, m)
        m = StructJuMP.getparent(m)
    end
    return
end

function build_submodels(root_model::StructJuMP.StructuredModel,
                         optimizer_factory::JuMP.OptimizerFactory,
                         phii::PHInitInfo{K}, ::Type{M}
                         ) where {K, M <: JuMP.AbstractModel}
    submodels = Dict{K,M}()
    variable_map = Dict{String, VariableInfo{K}}()
    for s in phii.scenarios
        m = JuMP.Model(optimizer_factory)
        lmodel = phii.leaves[s]

        add_variables(m, variable_map, phii.node_map, lmodel)
        add_objective(m, root_model, lmodel)
        add_constraints(m, lmodel)

        submodels[s] = m
    end

    return (submodels, variable_map)
end

function set_params(r::N, variable_map::Dict{String, VariableInfo{K}},
                    probs, phii::PHInitInfo{K}
                    ) where {N <: Number, K, M <: JuMP.AbstractModel}
    return PHParams(r, phii.scenarios, probs, variable_map)
end

function set_data(r::N, variable_map::Dict{String, VariableInfo{K}},
                  submodels::Dict{K,M}, probs, phii::PHInitInfo{K}
                  ) where {N <: Number, K, M <: JuMP.AbstractModel}
    php = set_params(r, variable_map, probs, phii)
    phd = PHData(phii, php, submodels)
    return phd
end

function compute_start_points(phd::PHData)
    
    # This is parallelizable
    for (scen, model) in pairs(phd.submodels)
        JuMP.optimize!(model)
    end
    
    return
end

function augment_objectives(phd::PHData)
    
    for (scen, model) in pairs(phd.submodels)

        obj = JuMP.objective_function(model)
        
        for var in JuMP.all_variables(model)
            # add "parameters" W and Xhat (to be fixed later)
            w_ref = VariableRef(model)
            set_name(w_ref, "W_" * JuMP.name(var))
            # JuMP.fix(w_ref, 0.0, force=true)
            
            xhat_ref = VariableRef(model)
            set_name(xhat_ref, "Xhat_" * JuMP.name(var))
        
            # appropriately modify the objective function
            obj += var*w_ref + 0.5 * phd.params.r * (var - xhat_ref)^2
        end

        JuMP.set_objective_function(model, obj)
    end
    
    return
end

function initialize(root_model::StructJuMP.StructuredModel, r::N,
                    optimizer_factory::JuMP.OptimizerFactory, ::Type{M}
                    ) where {N <: Number, M <: JuMP.AbstractModel}
    (phii, probs) = extract_structure(root_model)
    (submods, var_map) = build_submodels(root_model, optimizer_factory,
                                         phii, M)
    phd = set_data(r, var_map, submods, probs, phii)

    compute_start_points(phd)
    augment_objectives(phd)

    return phd
end
