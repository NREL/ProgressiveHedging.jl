#### Worker Structs ####

struct SubproblemRecord
    problem::AbstractSubproblem
    branch_vars::Vector{VariableID}
    leaf_vars::Vector{VariableID}
    subproblem_callbacks::Vector{SubproblemCallback}
end

mutable struct WorkerRecord
    id::Int
    warm_start::Bool
    subproblems::Dict{ScenarioID,SubproblemRecord}
    lb_subproblems::Dict{ScenarioID,SubproblemRecord}
end

function WorkerRecord(id::Int)
    return WorkerRecord(id,
                        false,
                        Dict{ScenarioID,SubproblemRecord}(),
                        Dict{ScenarioID,SubproblemRecord}(),
                        )
end

#### Worker Functions ####

function worker_loop(id::Int,
                     input::RemoteChannel,
                     output::RemoteChannel,
                     )::Int

    running = true
    my_record = WorkerRecord(id)

    try

        while running
            msg = take!(input)
            running = process_message(msg, my_record, output)
        end

    catch e

        while isready(input)
            take!(input)
        end

        rethrow()

    finally
        ; # intentional no-op
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

function process_message(msg::DumpState,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool
    put!(output, WorkerState(record.id, record))
    return true
end

function process_message(msg::Initialize,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool

    # record.warm_start = msg.warm_start

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
                       msg.subproblem_callbacks
                       )

    _initial_solve(output, record)

    _penalty_parameter_preprocess(output, record, msg.r)

    return true
end

function process_message(msg::InitializeLowerBound,
                         record::WorkerRecord,
                         output::RemoteChannel,
                         )::Bool

    for scen in msg.scenarios
        lb_sub = msg.create_subproblem(scen,
                                       msg.create_subproblem_args...;
                                       msg.create_subproblem_kwargs...
                                       )
        var_map = report_variable_info(lb_sub, msg.scenario_tree)
        (branch_ids, leaf_ids) = _split_variables(msg.scenario_tree,
                                                  collect(keys(var_map))
                                                  )
        add_lagrange_terms(lb_sub, branch_ids)
        record.lb_subproblems[scen] = SubproblemRecord(lb_sub,
                                                       branch_ids,
                                                       leaf_ids,
                                                       SubproblemCallback[]
                                                       )
    end

    return true

end

function process_message(msg::PenaltyInfo,
                         record::WorkerRecord,
                         output::RemoteChannel,
                         )::Bool

    if !haskey(record.subproblems, msg.scen)
        error("Worker $(record.id) received penalty parameter values for scenario $(msg.scen). This worker was not assigned this scenario.")
    end

    sub = record.subproblems[msg.scen]

    add_ph_objective_terms(sub.problem,
                           sub.branch_vars,
                           msg.penalty)

    return true
end

function process_message(msg::Ping,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool
    put!(output, Ping())
    return true
end

function process_message(msg::Solve,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool

    if !haskey(record.subproblems, msg.scen)
        error("Worker $(record.id) received solve command for scenario $(msg.scen). This worker was not assigned this scenario.")
    end

    sub = record.subproblems[msg.scen]

    if record.warm_start == true
        warm_start(sub.problem)
    end

    update_ph_terms(sub.problem, msg.w_vals, msg.xhat_vals)

    _execute_subproblem_callbacks(sub, msg.niter, msg.scen)

    start = time()
    sts = solve_subproblem(sub.problem)
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

function process_message(msg::SolveLowerBound,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool

    if !haskey(record.lb_subproblems, msg.scen)
        error("Worker $(record.id) received lower-bound solve command for scenario $(msg.scen). This worker was not assigned this scenario.")
    end

    lb_sub = record.lb_subproblems[msg.scen]

    if record.warm_start == true
        warm_start(lb_sub.problem)
    end

    update_lagrange_terms(lb_sub.problem, msg.w_vals)

    start = time()
    sts = solve_subproblem(lb_sub.problem)
    stop = time()

    put!(output, ReportLowerBound(msg.scen,
                                  sts,
                                  objective_value(lb_sub.problem),
                                  stop - start)
         )

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

function process_message(msg::SubproblemAction,
                         record::WorkerRecord,
                         output::RemoteChannel
                         )::Bool

    sub = record.subproblems[msg.scen].problem
    msg.action(sub, msg.args...; msg.kwargs...)

    return true

end

#### Internal Functions ####

function _build_subproblems(output::RemoteChannel,
                            record::WorkerRecord,
                            scenarios::Set{ScenarioID},
                            scen_tree::ScenarioTree,
                            create_subproblem::Function,
                            create_subproblem_args::Tuple,
                            create_subproblem_kwargs::NamedTuple,
                            subproblem_callbacks::Vector{SubproblemCallback}
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
                                                    leaf_ids,
                                                    subproblem_callbacks
                                                    )
    end

    return

end

function _execute_subproblem_callbacks(sub::SubproblemRecord,
                                       niter::Int,
                                       scen::ScenarioID
                                       )::Nothing

    for spcb in sub.subproblem_callbacks
        spcb.h(spcb.ext, sub.problem, niter, scen)
    end

    return

end

function _initial_solve(output::RemoteChannel,
                        record::WorkerRecord
                        )::Nothing

    for (scen, sub) in record.subproblems

        start = time()
        sts = solve_subproblem(sub.problem)
        stop = time()
        
        var_vals = report_values(sub.problem, sub.branch_vars)
        put!(output, ReportBranch(scen,
                                  sts,
                                  objective_value(sub.problem),
                                  stop - start,
                                  var_vals)
             )

        # if record.warm_start == true
        #     warm_start(sub.problem)
        # end

    end

    return

end

function _penalty_parameter_preprocess(output::RemoteChannel,
                                       record::WorkerRecord,
                                       r::Type{P},
                                       ) where P <: AbstractPenaltyParameter

    if is_subproblem_dependent(r)
        for (scen, sub) in record.subproblems
            pen_map = report_penalty_info(sub.problem, sub.branch_vars, r)
            put!(output, PenaltyInfo(scen, pen_map))
        end
    end

    return

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
