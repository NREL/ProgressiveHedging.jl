
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
                    report::Int,
                    constructor_args::Tuple,;
                    kwargs...
                    )::PHData where {S <: AbstractString,
                                     R <: Real,
                                     M <: JuMP.AbstractModel}

    scen_tree = deepcopy(scenario_tree)

    if report > 0
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

function build_var_info(vref::JuMP.VariableRef)
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

function ef_add_variables(model::JuMP.Model,
                          smod::JuMP.Model,
                          s::ScenarioID,
                          node::ScenarioNode,
                          variable_dict::Dict{STAGE_ID, Vector{String}}
                          )

    var_map = Dict{JuMP.VariableRef, VariableInfo}()
    new_vars = Set{VariableInfo}()
    
    for var in variable_dict[_value(node.stage)]
        vref = JuMP.variable_by_name(smod, var)
        info = build_var_info(vref)
        vname = var * "_{" * stringify(_value.(scenario_bundle(node))) * "}"
        new_vref = JuMP.add_variable(model,
                                     JuMP.build_variable(_error, info),
                                     vname)
        vi = VariableInfo(new_vref, vname, node.id)
        var_map[vref] = vi
        push!(new_vars, vi)
    end

    return (var_map, new_vars)
end

function ef_map_variables(smod::JuMP.Model,
                          variable_dict::Dict{STAGE_ID, Vector{String}},
                          node::ScenarioNode,
                          new_vars::Set{VariableInfo},
                          )
    var_map = Dict{JuMP.VariableRef, VariableInfo}()

    for var in variable_dict[_value(node.stage)]

        vref = JuMP.variable_by_name(smod, var)

        for vinfo in new_vars

            @assert vinfo.node_id == node.id

            if occursin(var, vinfo.name)
                var_map[vref] = vinfo
            end

        end

    end

    return var_map
end

function ef_copy_variables(model::JuMP.Model,
                           smod::JuMP.Model,
                           s::ScenarioID,
                           tree::ScenarioTree,
                           variable_dict::Dict{STAGE_ID, Vector{String}},
                           node_var_map::Dict{NodeID, Set{VariableInfo}},
                           )

    # Below for mapping variables in the subproblem model `smod` into variables for
    # the extensive form model `model`
    s_var_map = Dict{JuMP.VariableRef, VariableInfo}()

    # For saving updates to node_var_map and passing back up
    snode_var_map = Dict{NodeID, Set{VariableInfo}}()

    stack = [root(tree)]

    while !isempty(stack)

        node = pop!(stack)

        for c in node.children
            if s in scenario_bundle(c)
                push!(stack, c)
            end
        end

        # For the given model `smod`, either create extensive variables corresponding
        # to this node or map them onto existing extensive variables.
        if !(node.id in keys(node_var_map))
            (var_map, new_vars) = ef_add_variables(model, smod, s, node,
                                                   variable_dict)
            snode_var_map[node.id] = new_vars
        else
            var_map = ef_map_variables(smod,
                                       variable_dict,
                                       node,
                                       node_var_map[node.id])
        end

        @assert(isempty(intersect(keys(s_var_map), keys(var_map))))
        merge!(s_var_map, var_map)
    end

    return (snode_var_map, s_var_map)
end

function ef_convert_and_add_expr(add_to::JuMP.QuadExpr,
                                 convert::JuMP.AffExpr,
                                 s_var_map::Dict{JuMP.VariableRef,VariableInfo},
                                 scalar::R,
                                 )::Set{NodeID} where R <: Real

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

function ef_convert_and_add_expr(add_to::JuMP.QuadExpr,
                                 convert::JuMP.QuadExpr,
                                 s_var_map::Dict{JuMP.VariableRef,VariableInfo},
                                 scalar::R,
                                 )::Set{NodeID} where R <: Real

    nodes = ef_convert_and_add_expr(add_to, convert.aff, s_var_map, scalar)

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

function ef_copy_constraints(model::JuMP.Model,
                             smod::JuMP.Model,
                             s_var_map::Dict{JuMP.VariableRef,VariableInfo},
                             processed::Set{NodeID},
                             )::Nothing

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
            nodes = ef_convert_and_add_expr(expr,
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

function ef_copy_objective(model::JuMP.Model,
                           smod::JuMP.Model,
                           s_var_map::Dict{JuMP.VariableRef,VariableInfo},
                           prob::R
                           )::Nothing where R <: Real

    add_obj = JuMP.objective_function(smod)
    obj = JuMP.objective_function(model)
    ef_convert_and_add_expr(obj, add_obj, s_var_map, prob)
    JuMP.drop_zeros!(obj)
    JuMP.set_objective_function(model, obj)

    return
end

function ef_copy_model(model::JuMP.Model,
                       smod::JuMP.Model,
                       s::ScenarioID,
                       tree::ScenarioTree,
                       variable_dict::Dict{STAGE_ID, Vector{String}},
                       node_var_map::Dict{NodeID, Set{VariableInfo}},
                       )

    (snode_var_map, s_var_map) = ef_copy_variables(model, smod, s, tree,
                                                   variable_dict, node_var_map)
    processed = Set(keys(node_var_map))
    ef_copy_constraints(model, smod, s_var_map, processed)
    ef_copy_objective(model, smod, s_var_map, tree.prob_map[s])

    return snode_var_map
end

function build_extensive_form(optimizer::Function,
                              tree::ScenarioTree,
                              variable_dict::Dict{STAGE_ID,Vector{String}},
                              model_constructor::Function,
                              constructor_args::Tuple;
                              kwargs...
                              )::JuMP.Model

    model = JuMP.Model(optimizer)
    JuMP.set_objective_sense(model, MOI.MIN_SENSE)
    JuMP.set_objective_function(model, zero(JuMP.QuadExpr))

    # Below for mapping subproblem variables onto existing extensive form variables
    node_var_map = Dict{NodeID, Set{VariableInfo}}()

    for s in scenarios(tree)

        smod = model_constructor(_value(s), constructor_args...; kwargs...)

        snode_var_map = ef_copy_model(model, smod, s, tree,
                                      variable_dict, node_var_map)

        @assert(isempty(intersect(keys(node_var_map), keys(snode_var_map))))
        merge!(node_var_map, snode_var_map)
    end

    return model
end
