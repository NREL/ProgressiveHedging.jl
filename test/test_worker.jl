

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
