
@testset "Scenario Tree Functions" begin

    # First stage -- Creates root/first stage node automatically
    st = PH.ScenarioTree()

    # Second stage
    n1 = PH.add_node(st, PH.root(st))
    n2 = PH.add_node(st, PH.root(st))

    # Third stage
    sc0 = PH.add_leaf(st, n1, 0.25*0.75)
    sc1 = PH.add_leaf(st, n1, 0.75*0.75)
    sc2 = PH.add_leaf(st, n2, 0.25)

    @test length(n1.children) == 2
    (n3, n4) = n1.children
    if n3.id > n4.id
        temp = n4
        n4 = n3
        n3 = temp
    end
    @test length(n2.children) == 1
    n5 = first(n2.children) # only element in the set

    @test PH.last_stage(st) == PH.StageID(3)
    @test PH.is_leaf(st.root) == false
    @test PH.is_leaf(n1) == false
    @test PH.is_leaf(n2) == true # only having 1 child scenario means this is actually a leaf
    @test PH.is_leaf(n3) == true
    @test PH.is_leaf(n4) == true
    @test PH.is_leaf(n5) == true

    @test st.prob_map[sc0] == 0.25*0.75
    @test st.prob_map[sc1] == 0.75*0.75
    @test st.prob_map[sc2] == 0.25

    nodes = [st.root, n1, n2, n3, n4, n5]
    for n in nodes
        @test st.tree_map[n.id] == n
    end

    @test PH.scenarios(st) == Set([sc0, sc1, sc2])
    @test PH.scenario_bundle(st.root) == Set([sc0, sc1, sc2])
    @test PH.scenario_bundle(n1) == Set([sc0, sc1])
    @test PH.scenario_bundle(n2) == Set([sc2])
    @test PH.scenario_bundle(n3) == Set([sc0])
    @test PH.scenario_bundle(n4) == Set([sc1])
    @test PH.scenario_bundle(n5) == Set([sc2])

end

@testset "Workers" begin

    ch_size = 10

    @testset "Basics" begin
        worker_inf = PH._launch_workers(ch_size, ch_size)

        @test PH._number_workers(worker_inf) == 1
        @test PH._isrunning(worker_inf)

        my_task = @async begin
            PH._send_message(worker_inf, myid(), Ping())
            PH._retrieve_message_type(worker_inf, Ping)
        end
        @test timeout_wait(my_task)

        my_task = @async begin
            PH._abort(worker_inf)
            PH._wait_for_shutdown(worker_inf)
        end
        @test timeout_wait(my_task)

        @test !PH._isrunning(worker_inf)
        @test PH._number_workers(worker_inf) == 0
    end

    @testset "Error Handling" begin
        worker_inf = PH._launch_workers(ch_size, ch_size)

        struct MakeWorkerError <: PH.Message end

        PH._send_message(worker_inf, myid(), MakeWorkerError())
        my_task = @async begin
            PH._wait_for_shutdown(worker_inf)
        end
        if(timeout_wait(my_task))
            @test istaskfailed(my_task)
            @test typeof(my_task.exception) <: RemoteException
        else
            error("Test timed out")
        end
    end
end

@testset "Initialization" begin
    @testset "Build Subproblems" begin
        st = build_scen_tree()

        @test PH.last_stage(st) == PH.StageID(3)

        sc0 = PH.ScenarioID(0)
        sc1 = PH.ScenarioID(1)
        sc2 = PH.ScenarioID(2)
        sc3 = PH.ScenarioID(3)

        @test PH.scenarios(st) == Set([sc0, sc1, sc2, sc3])
        @test isapprox(sum(values(st.prob_map)), 1.0)
        @test isapprox(st.prob_map[sc0], 0.5*0.75)
        @test isapprox(st.prob_map[sc1], 0.5*0.25)
        @test isapprox(st.prob_map[sc2], 0.5*0.75)
        @test isapprox(st.prob_map[sc3], 0.5*0.25)

        wr = PH.WorkerRecord(myid())
        rc = RemoteChannel(()->Channel(2*length(PH.scenarios(st))), myid())

        PH._build_subproblems(rc, wr, PH.scenarios(st), st,
                              create_model, (), NamedTuple())

        for (scid, sub) in pairs(wr.subproblems)
            @test length(JuMP.all_variables(sub.problem.model)) == 6
            ncons = 0
            for (ftype,stype) in JuMP.list_of_constraint_types(sub.problem.model)
                ncons += JuMP.num_constraints(sub.problem.model, ftype, stype)
            end
            @test ncons == 7
        end

        count = 0
        my_var_map = Dict{PH.VariableID,String}()
        while isready(rc)
            count += 1
            msg = take!(rc)
            @test typeof(msg) <: PH.VariableMap
            merge!(my_var_map, msg.var_names)
            for (vid,vname) in pairs(msg.var_names)
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
                                       false)
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            var_map = fetch(my_task)

            for scen in PH.scenarios(st)
                for (vid, vname) in var_map[scen]
                    @test vid.scenario == scen
                    if vid.stage == PH.stid(1)
                        @test occursin("x", vname)
                    elseif vid.stage == PH.stid(2)
                        @test vname == "y"
                    elseif vid.stage == PH.stid(3)
                        @test occursin("z", vname)
                    else
                        stage_int = PH._value(vid.stage)
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
            while count < length(PH.scenarios(st))
                PH._retrieve_message_type(wi, PH.ReportBranch)
                count += 1
            end
            return count
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            num_msgs = fetch(my_task)
            @test num_msgs == length(PH.scenarios(st))
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timed out")
        end

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
                                       false)
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)

            var_map = fetch(my_task)

            for scen in PH.scenarios(st)
                for (vid, vname) in var_map[scen]
                    @test vid.scenario == scen
                    if vid.stage == PH.stid(1)
                        @test occursin("x", vname)
                    elseif vid.stage == PH.stid(2)
                        @test vname == "y"
                    elseif vid.stage == PH.stid(3)
                        @test occursin("z", vname)
                    else
                        stage_int = PH._value(vid.stage)
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
            count = 0
            messages = Vector{PH.PenaltyInfo}()
            while count < 2*length(PH.scenarios(st))
                msg = PH._retrieve_message_type(wi, Union{PH.ReportBranch,PH.PenaltyInfo})
                if typeof(msg) <: PH.PenaltyInfo
                    push!(messages, msg)
                end
                count += 1
            end

            for msg in messages
                put!(wi.output, msg)
            end
            return count
        end

        if timeout_wait(my_task, 90) && !istaskfailed(my_task)
            num_msgs = fetch(my_task)
            @test num_msgs == 2 * length(PH.scenarios(st))
        elseif istaskfailed(my_task)
            throw(my_task.exception)
        else
            error("Test timed out")
        end

        PH._set_penalty_parameter(phd, wi)

        for (xhid, xhat) in pairs(phd.xhat)
            vid = first(PH.variables(xhat))
            if vid.stage == PH.StageID(1)
                if vid.index == PH.Index(1)
                    @test isapprox(phd.r.penalties[xhid], 1.0)
                elseif vid.index == PH.Index(2)
                    @test isapprox(phd.r.penalties[xhid], 10.0)
                elseif vid.index == PH.Index(3)
                    @test isapprox(phd.r.penalties[xhid], 0.01)
                else
                    error("Unexpected variable id: $vid")
                end
            elseif vid.stage == PH.StageID(2) && vid.index == PH.Index(1)
                @test isapprox(phd.r.penalties[xhid], 7.0)
            else
                error("Unexpected variable id: $vid")
            end
        end

    end
end
