#### JuMPSubproblem Implementation ####

struct JuMPSubproblem <: AbstractSubproblem
    model::JuMP.Model
    scenario::ScenarioID
    stage_map::Dict{StageID, Vector{JuMP.VariableRef}}
    vars::Dict{VariableID, JuMP.VariableRef}
    w_vars::Dict{VariableID, JuMP.VariableRef}
    xhat_vars::Dict{VariableID, JuMP.VariableRef}
end

function JuMPSubproblem(m::JuMP.Model,
                        scid::ScenarioID,
                        stage_map::Dict{StageID, Vector{JuMP.VariableRef}}
                        )::JuMPSubproblem
    return JuMPSubproblem(m, scid, stage_map,
                          Dict{VariableID, JuMP.VariableRef}(),
                          Dict{VariableID, JuMP.VariableRef}(),
                          Dict{VariableID, JuMP.VariableRef}()
                          )
end

## JuMPSubproblem Internal Structs ##

struct JSVariable
    ref::JuMP.VariableRef
    name::String
    node_id::NodeID
end

## JuMPSubproblem Penalty Parameter Functions ##

function get_penalty_value(r::Float64,
                           vid::VariableID,
                           )::Float64
    return r
end

function get_penalty_value(r::Dict{VariableID,Float64},
                           vid::VariableID
                           )::Float64
    return r[vid]
end

## AbstractSubproblem Interface Functions ##

function add_lagrange_terms(js::JuMPSubproblem,
                            vids::Vector{VariableID}
                            )::Nothing

    obj = JuMP.objective_function(js.model,
                                  JuMP.GenericQuadExpr{Float64, JuMP.VariableRef}
                                  )

    jvi = JuMP.VariableInfo(false, NaN,   # lower_bound
                            false, NaN,   # upper_bound
                            true, 0.0,    # fixed
                            false, NaN,   # start value
                            false, false) # binary, integer

    for vid in vids
        var = js.vars[vid]
        w_ref = JuMP.add_variable(js.model, JuMP.build_variable(error, jvi))
        JuMP.add_to_expression!(obj, w_ref, var)
        js.w_vars[vid] = w_ref
    end

    JuMP.set_objective_function(js.model, obj)

    return
end

function add_ph_objective_terms(js::JuMPSubproblem,
                                vids::Vector{VariableID},
                                r::Union{Float64,Dict{VariableID,Float64}},
                                )::Nothing
    add_lagrange_terms(js, vids)
    add_proximal_terms(js, vids, r)
    return
end

function objective_value(js::JuMPSubproblem)::Float64
    return JuMP.objective_value(js.model)
end

function report_penalty_info(js::JuMPSubproblem,
                             vids::Vector{VariableID},
                             ::Type{ProportionalPenaltyParameter},
                             )::Dict{VariableID,Float64}
    return objective_coefficients(js, vids)
end

function report_penalty_info(js::JuMPSubproblem,
                             vids::Vector{VariableID},
                             ::Type{SEPPenaltyParameter},
                             )::Dict{VariableID,Float64}
    return objective_coefficients(js, vids)
end

function report_values(js::JuMPSubproblem,
                       vars::Vector{VariableID}
                       )::Dict{VariableID,Float64}
    val_dict = Dict{VariableID, Float64}()
    for vid in vars
        val_dict[vid] = JuMP.value(js.vars[vid])
    end
    return val_dict
end

function report_variable_info(js::JuMPSubproblem,
                              st::ScenarioTree
                              )::Dict{VariableID, VariableInfo}

    var_info = Dict{VariableID, VariableInfo}()

    for node in scenario_nodes(st, js.scenario)

        stid = stage(node)

        for (k, var) in enumerate(js.stage_map[stid])
            vid = VariableID(js.scenario, stid, Index(k))
            js.vars[vid] = var
            var_info[vid] = VariableInfo(JuMP.name(var),
                                         JuMP.is_integer(var) || JuMP.is_binary(var),
                                         )
        end

    end

    return var_info
end

function solve(js::JuMPSubproblem)::MOI.TerminationStatusCode
    JuMP.optimize!(js.model)
    return JuMP.termination_status(js.model)
end

function update_lagrange_terms(js::JuMPSubproblem,
                               w_vals::Dict{VariableID,Float64}
                               )::Nothing

    for (wid, wval) in pairs(w_vals)
        JuMP.fix(js.w_vars[wid], wval, force=true)
    end

    return

end

function update_ph_terms(js::JuMPSubproblem,
                         w_vals::Dict{VariableID,Float64},
                         xhat_vals::Dict{VariableID,Float64}
                         )::Nothing

    update_lagrange_terms(js, w_vals)
    update_proximal_terms(js, xhat_vals)

    return

end

function warm_start(js::JuMPSubproblem)::Nothing
    for var in JuMP.all_variables(js.model)
        if !JuMP.is_fixed(var)
            JuMP.set_start_value(var, JuMP.value(var))
        end
    end
    return
end

function ef_copy_model(efm::JuMP.Model,
                       js::JuMPSubproblem,
                       scid::ScenarioID,
                       tree::ScenarioTree,
                       node_var_map::Dict{NodeID, Set{JSVariable}}
                       )::Dict{NodeID, Set{JSVariable}}

    (snode_var_map, s_var_map) = _ef_copy_variables(efm, js, scid, tree, node_var_map)
    processed = Set(keys(node_var_map))
    _ef_copy_constraints(efm, js, s_var_map, processed)
    _ef_copy_objective(efm, js, s_var_map, tree.prob_map[scid])

    return snode_var_map
end

function ef_node_dict_constructor(::Type{JuMPSubproblem})
    return Dict{NodeID, Set{JSVariable}}()
end

## JuMPSubproblem Specific Functions ##

function add_proximal_terms(js::JuMPSubproblem,
                            vids::Vector{VariableID},
                            r::Union{Float64,Dict{VariableID,Float64}}
                            )::Nothing

    obj = JuMP.objective_function(js.model,
                                  JuMP.GenericQuadExpr{Float64, JuMP.VariableRef}
                                  )

    jvi = JuMP.VariableInfo(false, NaN,   # lower_bound
                            false, NaN,   # upper_bound
                            true, 0.0,    # fixed
                            false, NaN,   # start value
                            false, false) # binary, integer

    for vid in vids
        var = js.vars[vid]
        xhat_ref = JuMP.add_variable(js.model, JuMP.build_variable(error, jvi))
        rho = get_penalty_value(r, vid)
        JuMP.add_to_expression!(obj, 0.5 * rho * (var - xhat_ref)^2)
        js.xhat_vars[vid] = xhat_ref
    end

    JuMP.set_objective_function(js.model, obj)

    return

end

function fix_variables(js::JuMPSubproblem,
                       vids::Dict{VariableID,Float64}
                       )::Nothing

    for (vid, val) in pairs(vids)
        JuMP.fix(js.vars[vid], val, force=true)
    end

    return

end

function objective_coefficients(js::JuMPSubproblem,
                                vids::Vector{VariableID},
                                )::Dict{VariableID,Float64}
    pen_dict = Dict{VariableID,Float64}()
    obj = JuMP.objective_function(js.model)
    for vid in vids
        pen_dict[vid] = JuMP.coefficient(obj, js.vars[vid])
    end
    return pen_dict
end

function update_proximal_terms(js::JuMPSubproblem,
                               xhat_vals::Dict{VariableID,Float64}
                               )::Nothing

    for (xhid, xhval) in pairs(xhat_vals)
        JuMP.fix(js.xhat_vars[xhid], xhval, force=true)
    end

    return

end

## JuMPSubproblem Internal Functions ##

function _build_var_info(vref::JuMP.VariableRef)
    hlb = JuMP.has_lower_bound(vref)
    hub = JuMP.has_upper_bound(vref)
    hf = JuMP.is_fixed(vref)
    ib = JuMP.is_binary(vref)
    ii = JuMP.is_integer(vref)

    return JuMP.VariableInfo(hlb,
                             hlb ? JuMP.lower_bound(vref) : 0,
                             hub,
                             hub ? JuMP.upper_bound(vref) : 0,
                             hf,
                             hf ? JuMP.fix_value(vref) : 0,
                             false, # Some solvers don't accept starting values
                             0,
                             ib,
                             ii)
end

function _ef_add_variables(model::JuMP.Model,
                           js::JuMPSubproblem,
                           s::ScenarioID,
                           node::ScenarioNode,
                           )

    smod = js.model

    var_map = Dict{JuMP.VariableRef, JSVariable}()
    new_vars = Set{JSVariable}()

    for vref in js.stage_map[node.stage]
        info = _build_var_info(vref)
        var = JuMP.name(vref)
        vname = var * "_{" * stringify(value.(scenario_bundle(node))) * "}"
        new_vref = JuMP.add_variable(model,
                                     JuMP.build_variable(error, info),
                                     vname)
        jsv = JSVariable(new_vref, vname, node.id)
        var_map[vref] = jsv
        push!(new_vars, jsv)
    end

    return (var_map, new_vars)
end

function _ef_map_variables(js::JuMPSubproblem,
                           node::ScenarioNode,
                           new_vars::Set{JSVariable},
                           )
    var_map = Dict{JuMP.VariableRef, JSVariable}()

    for vref in js.stage_map[stage(node)]

        var = JuMP.name(vref)

        for jsv in new_vars

            @assert jsv.node_id == node.id

            if occursin(var, jsv.name)
                var_map[vref] = jsv
            end

        end

    end

    return var_map
end

function _ef_copy_variables(model::JuMP.Model,
                            js::JuMPSubproblem,
                            s::ScenarioID,
                            tree::ScenarioTree,
                            node_var_map::Dict{NodeID, Set{JSVariable}},
                            )

    # Below for mapping variables in the subproblem model `smod` into variables for
    # the extensive form model `model`
    s_var_map = Dict{JuMP.VariableRef, JSVariable}()

    # For saving updates to node_var_map and passing back up
    snode_var_map = Dict{NodeID, Set{JSVariable}}()

    smod = js.model

    for node in scenario_nodes(tree, s)

        # For the given model `smod`, either create extensive variables corresponding
        # to this node or map them onto existing extensive variables.
        if !haskey(node_var_map, id(node))
            (var_map, new_vars) = _ef_add_variables(model, js, s, node)
            snode_var_map[node.id] = new_vars
        else
            var_map = _ef_map_variables(js,
                                        node,
                                        node_var_map[node.id])
        end

        @assert(isempty(intersect(keys(s_var_map), keys(var_map))))
        merge!(s_var_map, var_map)
    end

    return (snode_var_map, s_var_map)
end

function _ef_convert_and_add_expr(add_to::JuMP.QuadExpr,
                                  convert::JuMP.AffExpr,
                                  s_var_map::Dict{JuMP.VariableRef,JSVariable},
                                  scalar::Real,
                                  )::Set{NodeID}

    nodes = Set{NodeID}()

    JuMP.add_to_expression!(add_to, scalar * JuMP.constant(convert))

    for (coef, var) in JuMP.linear_terms(convert)
        vi = s_var_map[var]
        nvar = vi.ref
        JuMP.add_to_expression!(add_to, scalar*coef, nvar)

        push!(nodes, vi.node_id)
    end

    return nodes
end

function _ef_convert_and_add_expr(add_to::JuMP.QuadExpr,
                                  convert::JuMP.QuadExpr,
                                  s_var_map::Dict{JuMP.VariableRef,JSVariable},
                                  scalar::Real,
                                  )::Set{NodeID}

    nodes = _ef_convert_and_add_expr(add_to, convert.aff, s_var_map, scalar)

    for (coef, var1, var2) in JuMP.quad_terms(convert)
        vi1 = s_var_map[var1]
        vi2 = s_var_map[var2]

        nvar1 = vi1.ref
        nvar2 = vi2.ref
        JuMP.add_to_expression!(add_to, scalar*coef, nvar1, nvar2)

        push!(nodes, vi1.node_id)
        push!(nodes, vi2.node_id)
    end

    return nodes
end

function _ef_copy_constraints(model::JuMP.Model,
                              js::JuMPSubproblem,
                              s_var_map::Dict{JuMP.VariableRef,JSVariable},
                              processed::Set{NodeID},
                              )::Nothing

    smod = js.model
    constraint_list = JuMP.list_of_constraint_types(smod)

    for (func,set) in constraint_list

        if func == JuMP.VariableRef
            # These constraints are handled by the variable bounds
            # which are copied during copy variable creation so
            # we skip them
            continue
        end

        for cref in JuMP.all_constraints(smod, func, set)

            cobj = JuMP.constraint_object(cref)
            expr = zero(JuMP.QuadExpr)
            nodes = _ef_convert_and_add_expr(expr,
                                             JuMP.jump_function(cobj),
                                             s_var_map,
                                             1)

            # If all variables in the expression are from processed nodes,
            # then this constraint has already been added to the model
            # and can be skipped.
            if !issubset(nodes, processed)
                JuMP.drop_zeros!(expr)
                JuMP.@constraint(model, expr in JuMP.moi_set(cobj))
            end
        end
    end

    return
end

function _ef_copy_objective(model::JuMP.Model,
                            js::JuMPSubproblem,
                            s_var_map::Dict{JuMP.VariableRef,JSVariable},
                            prob::Real
                            )::Nothing

    add_obj = JuMP.objective_function(js.model)
    obj = JuMP.objective_function(model)
    _ef_convert_and_add_expr(obj, add_obj, s_var_map, prob)
    JuMP.drop_zeros!(obj)
    JuMP.set_objective_function(model, obj)

    return
end
