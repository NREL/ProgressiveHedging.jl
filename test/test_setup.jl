
@testset "Initialization" begin

    @testset "Split Variables" begin
        st = build_scen_tree()
        js = create_model(PH.scid(0))
        vid_name_map = PH.report_variable_info(js, st)
        (branch_ids, leaf_ids) = PH._split_variables(st, collect(keys(vid_name_map)))

        for br_vid in branch_ids
            vname = vid_name_map[br_vid].name
            @test (vname == "y") || occursin("x", vname)
            if vname == "y"
                @test br_vid.stage == PH.stid(2)
            else
                @test br_vid.stage == PH.stid(1)
            end
        end

        for lf_vid in leaf_ids
            vname = vid_name_map[lf_vid].name
            @test occursin("z", vname)
            @test lf_vid.stage == PH.stid(3)
        end
    end

    @testset "Build Subproblems" begin
        st = build_scen_tree()

        wr = PH.WorkerRecord(myid())
        rc = RemoteChannel(()->Channel(2*length(PH.scenarios(st))), myid())

        PH._build_subproblems(rc, wr, PH.scenarios(st), st,
                              create_model, (), NamedTuple(), SubproblemCallback[]
                              )

        for (scid, sub) in pairs(wr.subproblems)
            @test length(JuMP.all_variables(sub.problem.model)) == 6
            ncons = 0
            for (ftype,stype) in JuMP.list_of_constraint_types(sub.problem.model)
                ncons += JuMP.num_constraints(sub.problem.model, ftype, stype)
            end
            @test ncons == 7
        end

        count = 0
        my_var_map = Dict{PH.VariableID,PH.VariableInfo}()
        while isready(rc)
            count += 1
            msg = take!(rc)
            @test typeof(msg) <: PH.VariableMap
            merge!(my_var_map, msg.var_info)
            for (vid,vinfo) in pairs(msg.var_info)
                @test vid.scenario == msg.scen
            end
        end
        @test length(my_var_map) == 24
    end

    @testset "Initialize Subproblems (Scalar)" begin
        st = build_scen_tree()

        sp_map = Dict(1 => Set([PH.ScenarioID(0), PH.ScenarioID(1), PH.ScenarioID(2)]),
                      2 => Set([PH.ScenarioID(3)])
                      )

        worker_input_queues = Dict(1 => RemoteChannel(()->Channel{PH.Message}(10), myid()),
                                   2 => RemoteChannel(()->Channel{PH.Message}(10), myid())
                                   )
        worker_output_queue = RemoteChannel(()->Channel{PH.Message}(10), myid())
        futures = Dict(1 => remotecall(PH.worker_loop,
                                       myid(),
                                       1,
                                       worker_input_queues[1],
                                       worker_output_queue),
                       2 => remotecall(PH.worker_loop,
                                       myid(),
                                       2,
                                       worker_input_queues[2],
                                       worker_output_queue),
                       )
        wi = PH.WorkerInf(worker_input_queues, worker_output_queue, futures)

        my_task = @async begin
            PH._initialize_subproblems(sp_map,
                                       wi,
                                       st,
                                       create_model,
                                       (),
                                       PH.ScalarPenaltyParameter(1.0),
                                       false,
                                       SubproblemCallback[])
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            var_map = fetch(my_task)

            for scen in PH.scenarios(st)
                for (vid, vinfo) in var_map[scen]
                    vname = vinfo.name
                    @test vid.scenario == scen
                    if vid.stage == PH.stid(1)
                        @test occursin("x", vname)
                    elseif vid.stage == PH.stid(2)
                        @test vname == "y"
                    elseif vid.stage == PH.stid(3)
                        @test occursin("z", vname)
                    else
                        stage_int = PH.value(vid.stage)
                        error("Stage $(stage_int)! There is no stage $(stage_int)!!")
                    end
                end
            end

        elseif istaskfailed(my_task)

            throw(my_task.exception)

        else

            error("Test timed out")

        end

        phd = PH.PHData(PH.ScalarPenaltyParameter(1.0),
                        st,
                        sp_map,
                        var_map,
                        TimerOutputs.TimerOutput()
                        )

        for (xhid, xhat) in pairs(phd.xhat)
            vname = phd.variable_data[first(xhat.vars)].name
            for vid in xhat.vars
                @test xhid == phd.variable_data[vid].xhat_id
                @test vname == phd.variable_data[vid].name
            end
        end

        for (scen, sinfo) in phd.scenario_map
            for vid in keys(sinfo.branch_vars)
                if occursin("x", phd.variable_data[vid].name)
                    @test vid.stage == PH.stid(1)
                else
                    @test vid.stage == PH.stid(2)
                end
            end

            for vid in keys(sinfo.leaf_vars)
                @test vid.stage == PH.stid(3)
            end
        end

        my_task = @async begin
            count = 0
            messages = Vector{PH.Message}()
            while count < length(PH.scenarios(st))
                msg = PH._retrieve_message_type(wi, PH.ReportBranch)
                push!(messages, msg)
                count += 1
            end
            return messages
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            msgs = fetch(my_task)
            @test length(msgs) == length(PH.scenarios(st))
            msg_from_scen = Set{PH.ScenarioID}()

            for msg in msgs
                scen = msg.scen
                push!(msg_from_scen, scen)

                sinfo = phd.scenario_map[scen]
                @test keys(sinfo.branch_vars) == keys(msg.vals)
                @test (msg.sts == MOI.OPTIMAL ||
                       msg.sts == MOI.LOCALLY_SOLVED ||
                       msg.sts == MOI.ALMOST_LOCALLY_SOLVED
                       )

                put!(wi.output, msg)
            end

            @test msg_from_scen == PH.scenarios(st)

        elseif istaskfailed(my_task)

            throw(my_task.exception)

        else

            error("Test timed out")

        end

        my_task = @async PH._set_initial_values(phd, wi)

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            @test fetch(my_task) >= 0.0
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timedout")
        end

        my_task = @async PH._set_penalty_parameter(phd, wi)
        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            @test fetch(my_task) >= 0.0
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timedout")
        end

        PH._shutdown(wi)
        PH._wait_for_shutdown(wi)
    end

    @testset "Initialize Subproblems (Proportional)" begin
        st = build_scen_tree()

        sp_map = Dict(1 => Set([PH.ScenarioID(0), PH.ScenarioID(1), PH.ScenarioID(2)]),
                      2 => Set([PH.ScenarioID(3)])
                      )

        worker_input_queues = Dict(1 => RemoteChannel(()->Channel{PH.Message}(10), myid()),
                                   2 => RemoteChannel(()->Channel{PH.Message}(10), myid())
                                   )
        worker_output_queue = RemoteChannel(()->Channel{PH.Message}(10), myid())
        futures = Dict(1 => remotecall(PH.worker_loop,
                                       myid(),
                                       1,
                                       worker_input_queues[1],
                                       worker_output_queue),
                       2 => remotecall(PH.worker_loop,
                                       myid(),
                                       2,
                                       worker_input_queues[2],
                                       worker_output_queue),
                       )
        wi = PH.WorkerInf(worker_input_queues, worker_output_queue, futures)

        my_task = @async begin
            PH._initialize_subproblems(sp_map,
                                       wi,
                                       st,
                                       create_model,
                                       (),
                                       PH.ProportionalPenaltyParameter(1.0),
                                       false,
                                       SubproblemCallback[])
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            var_map = fetch(my_task)

            for scen in PH.scenarios(st)
                for (vid, vinfo) in var_map[scen]
                    vname = vinfo.name
                    @test vid.scenario == scen
                    if vid.stage == PH.stid(1)
                        @test occursin("x", vname)
                    elseif vid.stage == PH.stid(2)
                        @test vname == "y"
                    elseif vid.stage == PH.stid(3)
                        @test occursin("z", vname)
                    else
                        stage_int = PH.value(vid.stage)
                        error("Stage $(stage_int)! There is no stage $(stage_int)!!")
                    end
                end
            end

        elseif istaskfailed(my_task)

            throw(my_task.exception)

        else

            error("Test timed out")

        end

        phd = PH.PHData(PH.ProportionalPenaltyParameter(1.0),
                        st,
                        sp_map,
                        var_map,
                        TimerOutputs.TimerOutput()
                        )

        for (xhid, xhat) in pairs(phd.xhat)
            vname = phd.variable_data[first(xhat.vars)].name
            for vid in xhat.vars
                @test xhid == phd.variable_data[vid].xhat_id
                @test vname == phd.variable_data[vid].name
            end
        end

        for (scen, sinfo) in phd.scenario_map
            for vid in keys(sinfo.branch_vars)
                if occursin("x", phd.variable_data[vid].name)
                    @test vid.stage == PH.stid(1)
                else
                    @test vid.stage == PH.stid(2)
                end
            end

            for vid in keys(sinfo.leaf_vars)
                @test vid.stage == PH.stid(3)
            end
        end

        my_task = @async begin
            messages = Vector{PH.Message}()
            count = 0
            while count < 2*length(PH.scenarios(st))
                msg = PH._retrieve_message_type(wi, Union{PH.ReportBranch,PH.PenaltyInfo})
                push!(messages, msg)
                count += 1
            end
            return messages
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            msgs = fetch(my_task)
            @test length(msgs) == 2 * length(PH.scenarios(st))

            iv_msg_from_scen = Set{PH.ScenarioID}()
            pp_msg_from_scen = Set{PH.ScenarioID}()

            for msg in msgs

                scen = msg.scen
                sinfo = phd.scenario_map[scen]

                if typeof(msg) <: PH.ReportBranch
                    push!(iv_msg_from_scen, scen)
                    @test (msg.sts == MOI.OPTIMAL ||
                           msg.sts == MOI.LOCALLY_SOLVED ||
                           msg.sts == MOI.ALMOST_LOCALLY_SOLVED
                           )
                    @test keys(sinfo.branch_vars) == keys(msg.vals)
                elseif typeof(msg) <: PH.PenaltyInfo
                    push!(pp_msg_from_scen, scen)
                    @test keys(sinfo.branch_vars) == keys(msg.penalty)
                else
                    error("Unexpected message of type $(typeof(msg))")
                end

                put!(wi.output, msg)

            end

            @test iv_msg_from_scen == PH.scenarios(st)
            @test pp_msg_from_scen == PH.scenarios(st)

        elseif istaskfailed(my_task)

            throw(my_task.exception)

        else

            error("Test timed out")

        end

        my_task = @async PH._set_initial_values(phd, wi)
        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            @test fetch(my_task) >= 0.0
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timedout")
        end

        my_task = @async PH._set_penalty_parameter(phd, wi)
        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            @test fetch(my_task) >= 0.0
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timedout")
        end

        PH._shutdown(wi)
        PH._wait_for_shutdown(wi)
    end

    @testset "Initialize Subproblems (SEP)" begin
        st = build_scen_tree()

        sp_map = Dict(1 => Set([PH.ScenarioID(0), PH.ScenarioID(1), PH.ScenarioID(2)]),
                      2 => Set([PH.ScenarioID(3)])
                      )

        worker_input_queues = Dict(1 => RemoteChannel(()->Channel{PH.Message}(10), myid()),
                                   2 => RemoteChannel(()->Channel{PH.Message}(10), myid())
                                   )
        worker_output_queue = RemoteChannel(()->Channel{PH.Message}(10), myid())
        futures = Dict(1 => remotecall(PH.worker_loop,
                                       myid(),
                                       1,
                                       worker_input_queues[1],
                                       worker_output_queue),
                       2 => remotecall(PH.worker_loop,
                                       myid(),
                                       2,
                                       worker_input_queues[2],
                                       worker_output_queue),
                       )
        wi = PH.WorkerInf(worker_input_queues, worker_output_queue, futures)

        my_task = @async begin
            PH._initialize_subproblems(sp_map,
                                       wi,
                                       st,
                                       create_model,
                                       (),
                                       PH.SEPPenaltyParameter(),
                                       false,
                                       SubproblemCallback[])
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            var_map = fetch(my_task)

            for scen in PH.scenarios(st)
                for (vid, vinfo) in var_map[scen]
                    vname = vinfo.name
                    @test vid.scenario == scen
                    if vid.stage == PH.stid(1)
                        @test occursin("x", vname)
                    elseif vid.stage == PH.stid(2)
                        @test vname == "y"
                    elseif vid.stage == PH.stid(3)
                        @test occursin("z", vname)
                    else
                        stage_int = PH.value(vid.stage)
                        error("Stage $(stage_int)! There is no stage $(stage_int)!!")
                    end
                end
            end

        elseif istaskfailed(my_task)

            throw(my_task.exception)

        else

            error("Test timed out")

        end

        phd = PH.PHData(PH.SEPPenaltyParameter(),
                        st,
                        sp_map,
                        var_map,
                        TimerOutputs.TimerOutput()
                        )

        for (xhid, xhat) in pairs(phd.xhat)
            vname = phd.variable_data[first(xhat.vars)].name
            for vid in xhat.vars
                @test xhid == phd.variable_data[vid].xhat_id
                @test vname == phd.variable_data[vid].name
            end
        end

        for (scen, sinfo) in phd.scenario_map
            for vid in keys(sinfo.branch_vars)
                if occursin("x", phd.variable_data[vid].name)
                    @test vid.stage == PH.stid(1)
                else
                    @test vid.stage == PH.stid(2)
                end
            end

            for vid in keys(sinfo.leaf_vars)
                @test vid.stage == PH.stid(3)
            end
        end

        my_task = @async begin
            messages = Vector{PH.Message}()
            count = 0
            while count < 2*length(PH.scenarios(st))
                msg = PH._retrieve_message_type(wi, Union{PH.ReportBranch,PH.PenaltyInfo})
                push!(messages, msg)
                count += 1
            end
            return messages
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            msgs = fetch(my_task)
            @test length(msgs) == 2 * length(PH.scenarios(st))

            iv_msg_from_scen = Set{PH.ScenarioID}()
            pp_msg_from_scen = Set{PH.ScenarioID}()

            for msg in msgs

                scen = msg.scen
                sinfo = phd.scenario_map[scen]

                if typeof(msg) <: PH.ReportBranch
                    push!(iv_msg_from_scen, scen)
                    @test (msg.sts == MOI.OPTIMAL ||
                           msg.sts == MOI.LOCALLY_SOLVED ||
                           msg.sts == MOI.ALMOST_LOCALLY_SOLVED
                           )
                    @test keys(sinfo.branch_vars) == keys(msg.vals)
                elseif typeof(msg) <: PH.PenaltyInfo
                    push!(pp_msg_from_scen, scen)
                    @test keys(sinfo.branch_vars) == keys(msg.penalty)
                else
                    error("Unexpected message of type $(typeof(msg))")
                end

                put!(wi.output, msg)

            end

            @test iv_msg_from_scen == PH.scenarios(st)
            @test pp_msg_from_scen == PH.scenarios(st)

        elseif istaskfailed(my_task)

            throw(my_task.exception)

        else

            error("Test timed out")

        end

        my_task = @async PH._set_initial_values(phd, wi)
        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            @test fetch(my_task) >= 0.0
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timedout")
        end

        my_task = @async PH._set_penalty_parameter(phd, wi)
        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            @test fetch(my_task) >= 0.0
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timedout")
        end

        PH._shutdown(wi)
        PH._wait_for_shutdown(wi)
    end

end
