
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
                                 warm_start::Bool;
                                 kwargs...
                                 )

    # Send initialization commands
    @sync for (wid, scenarios) in pairs(sp_map)
        # println("......initializing worker $wid with scenarios $scenarios")
        # flush(stdout)
        @async _send_message(wi,
                             wid,
                             Initialize(constructor,
                                        constructor_args,
                                        (;kwargs...),
                                        r,
                                        scenarios,
                                        scen_tree,
                                        warm_start)
                             )
    end

    # Wait for and process initialization replies
    var_maps = Dict{ScenarioID,Dict{VariableID,String}}()
    for s in scenarios(scen_tree)
        var_maps[s] = Dict{VariableID,String}()
    end

    remaining_maps = copy(scenarios(scen_tree))
    msg_waiting = Vector{Union{ReportBranch,PenaltyMap}}()

    while !isempty(remaining_maps)

        msg = _retrieve_message_type(wi, Union{ReportBranch,VariableMap,PenaltyMap})

        if typeof(msg) <: ReportBranch || typeof(msg) <: PenaltyMap

            # println("Got branch report for $(msg.scen).")
            # _copy_values(init_vals[msg.scen], msg.vals)
            # delete!(remaining_vals, msg.scen)
            push!(msg_waiting, msg)

        elseif typeof(msg) <: VariableMap

            # println("Got variable map for $(msg.scen).")
            var_maps[msg.scen] = msg.var_names
            delete!(remaining_maps, msg.scen)

        else

            error("Inconceivable!!!!")

        end

    end

    # Put any initial value messages back
    for msg in msg_waiting
        put!(wi.output, msg)
    end

    return var_maps
end

function _set_initial_values(phd::PHData,
                             winf::WorkerInf,
                             )::Nothing

    _process_reports(phd, winf, ReportBranch)

    return
end

function _map_penalty_coefficients(ph_data::PHData
                                    w::WorkerInf,
                                    r::AbstractPenaltyParameter
                                    )::Nothing
    throw(UninmplementedError("_map_penalty_coefficients uninmplemented for penalty of type $(typeof(r))"))
end

function _map_penalty_coefficients(ph_data::PHData
                                    w::WorkerInf,
                                    r::ScalarPenaltyParameter
                                    )::Nothing
    return 
end

function _map_penalty_coefficients(ph_data::PHData
                                    w::WorkerInf,
                                    r::ProportionalPenaltyParameter
                                    )::Nothing
    # Wait for and process mapping replies
    coefficient = r.coefficient
    remaining_maps = copy(scenarios(ph_data.scenario_tree))
    msg_waiting = Vector{Union{ReportBranch}}()

    while !isempty(remaining_maps)

        msg = _retrieve_message_type(wi, Union{ReportBranch,PenaltyMap})

        if typeof(msg) <: ReportBranch

            push!(msg_waiting, msg)

        elseif typeof(msg) <: PenaltyMap

            for (var_id, coeff) in msg.var_penalties
                xhat_id = convert_to_xhat_id(ph_data, var_id)
                coefficient[xhat_id] = coeff
            end
            delete!(remaining_maps, msg.scen)

        else

            error("Inconceivable!!!!")

        end

    end

    # Put any initial value messages back
    for msg in msg_waiting
        put!(wi.output, msg)
    end

    return 
end

function initialize(scen_tree::ScenarioTree,
                    model_constructor::Function,
                    r::AbstractPenaltyParameter,
                    warm_start::Bool,
                    timo::TimerOutputs.TimerOutput,
                    report::Int,
                    constructor_args::Tuple,;
                    kwargs...
                    )::Tuple{PHData,WorkerInf}

    # Assign scenarios to processes
    scen_proc_map = assign_scenarios_to_procs(scen_tree)
    scen_per_worker = maximum(length.(collect(values(scen_proc_map))))
    n_scenarios = length(scenarios(scen_tree))

    # Start worker loops
    if report > 0
        println("...launching workers...")
    end
    worker_inf = @timeit(timo,
                         "Launch Workers",
                         _launch_workers(scen_per_worker, n_scenarios)
                         )

    # Initialize workers
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
                                              warm_start;
                                              kwargs...)
                      )

    # Construct master ph object
    ph_data = @timeit(timo,
                      "Other",
                      PHData(r,
                             scen_tree,
                             scen_proc_map,
                             var_map,
                             timo)
                      )
    
    # Map penalty parameter coefficients (xhatid ---> penalty coefficient)
    # This should be possible, since initialization message called
    # _augment_subproblems, which created penalty_map
    # And PHData has a mapping of variableid ---> xhatid
    r = @timit(timo,
                "Map penalty coefficients",
                _map_penalty_coefficients(ph_data, 
                                            worker_inf,
                                            r
                                        )
                )

    # Initial values
    _set_initial_values(ph_data, worker_inf)

    return (ph_data, worker_inf)
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
