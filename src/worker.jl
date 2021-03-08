
struct SubproblemRecord
    problem::AbstractSubproblem
    branch_vars::Vector{VariableID}
    leaf_vars::Vector{VariableID}
end

mutable struct WorkerRecord
    id::Int
    initialized::Bool
    warm_start::Bool
    subproblems::Dict{ScenarioID,SubproblemRecord}
end

function WorkerRecord(id::Int)
    return WorkerRecord(id,
                        false,
                        false,
                        Dict{ScenarioID,SubproblemRecord}(),
                        )
end

function worker_loop(id::Int,
                     input::RemoteChannel,
                     output::RemoteChannel,
                     )::Int

    # println("Worker $(myid()) launching...")
    # flush(stdout)

    running = true
    my_record = WorkerRecord(id)

    try

        while running
            # println("Worker $(myid()) waiting for message...")
            # flush(stdout)
            msg = take!(input)
            running = process_message(msg, my_record, output)
        end

    catch e

        while isready(input)
            take!(input)
        end

        # println("Caught an error: $e")
        # flush(stdout)

        rethrow()

    finally
        ; # nothing for now
    end

    return 0
end

function process_message(msg::Message,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool
    error("Worker unable to process message type: $(typeof(msg))")
    return false
end

function process_message(msg::Abort,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool
    return false
end

function process_message(msg::Initialize,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool

    # println("Worker $(record.id) processing init message...")
    # flush(stdout)

    record.warm_start = msg.warm_start

    # Master process needs the variable map messages to proceed. Initial solves are
    # not needed until much later in the process. So get all variable maps back first
    # then start working on the initial solves and the objective augmentation

    _build_subproblems(output,
                       record,
                       msg.scenarios,
                       msg.scenario_tree,
                       msg.create_subproblem,
                       msg.create_subproblem_args,
                       msg.create_subproblem_kwargs,
                       )

    
    _initial_solve(output, record)

    _augment_subproblems(output, record, msg.r)

    record.initialized = true

    # println("Worker $(record.id) completed initialization.")
    # flush(stdout)

    return true
end

function process_message(msg::Ping,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool
    put!(output, Ping())
    return true
end

function process_message(msg::ShutDown,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool

    for (s, sub) in pairs(record.subproblems)
        leaf_vals = report_values(sub.problem, sub.leaf_vars)
        put!(output, ReportLeaf(s, leaf_vals))
    end

    return false
end

function process_message(msg::Solve,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool

    # println("Worker $(record.id) received solve command for $(msg.scen).")

    if !record.initialized
        error("Worker $(record.id) received solve command before initialization")
    end

    if !haskey(record.subproblems, msg.scen)
        error("Worker $(record.id) received solve command for scenario $(msg.scen). This worker was not assigned this scenario")
    end

    sub = record.subproblems[msg.scen]

    update_ph_terms(sub.problem, msg.w_vals, msg.xhat_vals)

    if record.warm_start
        warm_start(sub.problem)
    end

    start = time()
    sts = solve(sub.problem)
    stop = time()
    var_vals = report_values(sub.problem, sub.branch_vars)

    put!(output, ReportBranch(msg.scen,
                              sts,
                              objective_value(sub.problem),
                              stop - start,
                              var_vals)
         )

    return true
end

function process_message(msg::PenaltyMap,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )
    # WHAT HERE?
    return true
end

function _split_variables(scen_tree::ScenarioTree,
                          vars::Vector{VariableID},
                          )::NTuple{2,Vector{VariableID}}

    branch_vars = Vector{VariableID}()
    leaf_vars = Vector{VariableID}()

    for vid in vars
        if is_leaf(scen_tree, vid)
            push!(leaf_vars, vid)
        else
            push!(branch_vars, vid)
        end
    end

    return (branch_vars, leaf_vars)
end

function _build_subproblems(output::RemoteChannel,
                            record::WorkerRecord,
                            scenarios::Set{ScenarioID},
                            scen_tree::ScenarioTree,
                            create_subproblem::Function,
                            create_subproblem_args::Tuple,
                            create_subproblem_kwargs::NamedTuple,
                            )::Nothing
    for scen in scenarios

        # Create subproblem
        sub = create_subproblem(scen,
                                create_subproblem_args...;
                                create_subproblem_kwargs...)

        # Assign variable ids (scenario, stage, index) to variable names and send
        # that map to the master process -- master process expects names to match
        # for variables that have anticipativity constraints
        var_map = report_variable_info(sub, scen_tree)
        put!(output, VariableMap(scen, var_map))

        # Break variables into branch and leaf
        (branch_ids, leaf_ids) = _split_variables(scen_tree,
                                                  collect(keys(var_map)))

        # Save subproblem and relevant data
        record.subproblems[scen] = SubproblemRecord(sub,
                                                    branch_ids,
                                                    leaf_ids)
    end

    return
end

function _initial_solve(output::RemoteChannel,
                        record::WorkerRecord
                        )::Nothing

    for (scen, sub) in record.subproblems

        start = time()
        sts = solve(sub.problem)
        stop = time()
        var_vals = report_values(sub.problem, sub.branch_vars)
        put!(output, ReportBranch(scen,
                                  sts,
                                  objective_value(sub.problem),
                                  stop - start,
                                  var_vals)
             )

    end

    return
end

function _augment_subproblems(output::RemoteChannel,
                              record::WorkerRecord,
                              r::AbstractPenaltyParameter
                              )

    penalty_map = Dict{ScenarioID,Dict{VariableID,Real}}()
    for (scen, sub) in record.subproblems
        put!(output, PenaltyMap(
                                scen,
                                add_ph_objective_terms(sub.problem,
                                                       sub.branch_vars,
                                                       r
                                                       ),
                               )
            )
    end
end
