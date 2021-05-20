
function assign_scenarios_to_procs(scen_tree::ScenarioTree
                                   )::Dict{Int,Set{ScenarioID}}
    sp_map = Dict{Int, Set{ScenarioID}}()

    nprocs = nworkers()
    wrks = workers()
    sp_map = Dict(w => Set{ScenarioID}() for w in wrks)

    for (k,s) in enumerate(scenarios(scen_tree))
        w = wrks[(k-1) % nprocs + 1]
        push!(sp_map[w], s)
    end

    return sp_map
end

function _initialize_subproblems(sp_map::Dict{Int,Set{ScenarioID}},
                                 wi::WorkerInf,
                                 scen_tree::ScenarioTree,
                                 constructor::Function,
                                 constructor_args::Tuple,
                                 r::AbstractPenaltyParameter,
                                 warm_start::Bool,
                                 subproblem_callbacks::Vector{SubproblemCallback};
                                 kwargs...
                                 )

    # Send initialization commands
    @sync for (wid, scenarios) in pairs(sp_map)
        @async _send_message(wi,
                             wid,
                             Initialize(constructor,
                                        constructor_args,
                                        (;kwargs...),
                                        typeof(r),
                                        scenarios,
                                        scen_tree,
                                        warm_start,
                                        subproblem_callbacks)
                             )
    end

    # Wait for and process initialization replies
    var_maps = Dict{ScenarioID,Dict{VariableID,VariableInfo}}()
    remaining_maps = copy(scenarios(scen_tree))

    while !isempty(remaining_maps)

        msg = _retrieve_message_type(wi, VariableMap)
        var_maps[msg.scen] = msg.var_info

        delete!(remaining_maps, msg.scen)

    end

    return var_maps
end

function _initialize_lb_subproblems(sp_map::Dict{Int,Set{ScenarioID}},
                                    wi::WorkerInf,
                                    scen_tree::ScenarioTree,
                                    constructor::Function,
                                    constructor_args::Tuple,
                                    warm_start::Bool;
                                    kwargs...
                                    )::Nothing

    @sync for (wid, scenarios) in pairs(sp_map)
        @async _send_message(wi,
                             wid,
                             InitializeLowerBound(constructor,
                                                  constructor_args,
                                                  (;kwargs...),
                                                  scenarios,
                                                  scen_tree,
                                                  warm_start)
                             )
    end

    return
end

function _set_initial_values(phd::PHData,
                             wi::WorkerInf,
                             )::Float64

    # Wait for and process mapping replies
    remaining_init = copy(scenarios(phd.scenario_tree))

    while !isempty(remaining_init)

        msg = _retrieve_message_type(wi, ReportBranch)

        _verify_report(msg)
        _update_values(phd, msg)

        delete!(remaining_init, msg.scen)

    end

    # Start computation of initial PH values -- W values are computed at
    # the end of `_set_penalty_parameter`.
    xhat_res_sq = compute_and_save_xhat(phd)

    return xhat_res_sq
end

function _set_penalty_parameter(phd::PHData,
                                wi::WorkerInf,
                                )::Float64

    if is_subproblem_dependent(typeof(phd.r))

        # Wait for and process penalty parameter messages
        remaining_maps = copy(scenarios(phd.scenario_tree))

        while !isempty(remaining_maps)

            msg = _retrieve_message_type(wi, PenaltyInfo)

            process_penalty_subproblem(phd.r, phd, msg.scen, msg.penalty)

            delete!(remaining_maps, msg.scen)

        end

    end

    if is_initial_value_dependent(typeof(phd.r))

        # Compute penalty parameter values
        process_penalty_initial_value(phd.r, phd)

    end

    if is_variable_dependent(typeof(phd.r))

        # Convert dictionary to subproblem format
        pen_map = Dict{ScenarioID,Dict{VariableID,Float64}}(
            s => Dict{VariableID,Float64}() for s in scenarios(phd)
        )

        for (xhid,penalty) in pairs(penalty_map(phd.r))
            for vid in convert_to_variable_ids(phd, xhid)
                pen_map[scenario(vid)][vid] = penalty
            end
        end

    else

        pen_map = Dict{ScenarioID,Float64}(
            s => get_penalty_value(phd.r) for s in scenarios(phd)
        )

    end

    # Send penalty parameter values to workers
    @sync for (scid, sinfo) in pairs(phd.scenario_map)
        @async begin
            wid = sinfo.pid
            penalty = pen_map[scid]
            _send_message(wi, wid, PenaltyInfo(scid, penalty))
        end
    end

    # Complete computation of initial PH values -- Xhat values are computed at
    # the end of `_set_initial_values`.
    x_res_sq = compute_and_save_w(phd)

    return x_res_sq
end

function initialize(scen_tree::ScenarioTree,
                    model_constructor::Function,
                    r::AbstractPenaltyParameter,
                    user_sp_map::Dict{Int,Set{ScenarioID}},
                    warm_start::Bool,
                    timo::TimerOutputs.TimerOutput,
                    report::Int,
                    lower_bound::Int,
                    subproblem_callbacks::Vector{SubproblemCallback},
                    constructor_args::Tuple,;
                    kwargs...
                    )::Tuple{PHData,WorkerInf}

    # Assign scenarios to processes
    scen_proc_map = isempty(user_sp_map) ? assign_scenarios_to_procs(scen_tree) : user_sp_map
    scen_per_worker = maximum(length.(collect(values(scen_proc_map))))
    n_scenarios = length(scenarios(scen_tree))

    # Start worker loops
    if report > 0
        println("...launching workers...")
    end
    worker_inf = @timeit(timo,
                         "Launch Workers",
                         _launch_workers(2*scen_per_worker, n_scenarios)
                         )

    # Initialize subproblems
    if report > 0
        println("...initializing subproblems...")
        flush(stdout)
    end

    var_map = @timeit(timo,
                      "Initialize Subproblems",
                      _initialize_subproblems(scen_proc_map,
                                              worker_inf,
                                              scen_tree,
                                              model_constructor,
                                              constructor_args,
                                              r,
                                              warm_start,
                                              subproblem_callbacks;
                                              kwargs...)
                      )

    if lower_bound > 0

        if report > 0
            println("...initializing lower-bound subproblems...")
            flush(stdout)
        end

        @timeit(timo,
                "Initialze Lower Bound Subproblems",
                _initialize_lb_subproblems(scen_proc_map,
                                           worker_inf,
                                           scen_tree,
                                           model_constructor,
                                           constructor_args,
                                           warm_start;
                                           kwargs...)
                )

    end

    # Construct master ph object
    phd = @timeit(timo,
                  "Other",
                  PHData(r,
                         scen_tree,
                         scen_proc_map,
                         var_map,
                         timo)
                  )

    # Initial values
    xhat_res_sq = @timeit(timo,
                          "Initial Values",
                          _set_initial_values(phd, worker_inf)
                          )

    # Check for penalty parameter update
    x_res_sq = @timeit(timo,
                       "Penalty Parameter",
                       _set_penalty_parameter(phd,
                                              worker_inf)
                       )

    # Save residual
    _save_residual(phd, -1, xhat_res_sq, x_res_sq, 0.0, 0.0)

    return (phd, worker_inf)
end

function build_extensive_form(tree::ScenarioTree,
                              model_constructor::Function,
                              constructor_args::Tuple,
                              sub_type::Type{S};
                              kwargs...
                              )::JuMP.Model where {S <: AbstractSubproblem}

    model = JuMP.Model()
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
