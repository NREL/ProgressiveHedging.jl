
r = PH.ScalarPenaltyParameter(25.0)
atol = 1e-8
rtol = 1e-12
max_iter = 500
obj_val = 178.3537498401004
var_vals = Dict([
    "x[1]_{0,1,2,3}" => 7.5625,
    "x[2]_{0,1,2,3}" => 0.0,
    "x[3]_{0,1,2,3}" => 1.0,
    "y_{0,1}" => 1.75,
    "y_{2,3}" => 0.0,
    "z[1]_{0}" => -0.65625,
    "z[2]_{0}" => -0.65625,
    "z[1]_{1}" => 2.84375,
    "z[2]_{1}" => 2.84375,
    "z[1]_{2}" => -1.78125,
    "z[2]_{2}" => -1.78125,
    "z[1]_{3}" => 4.71875,
    "z[2]_{3}" => 4.71875,
])

# Setup distributed stuff
nw = 2
diff = nw - nworkers()
diff > 0 && Distributed.addprocs(nw)
@assert Distributed.nworkers() == nw
@everywhere using Pkg
@everywhere Pkg.activate(@__DIR__)
@everywhere using ProgressiveHedging
@everywhere const PH = ProgressiveHedging
@everywhere using Ipopt
@everywhere using JuMP
include("common.jl")

@testset "Distributed Error Handling" begin
    ch_size = 10
    worker_inf = PH._launch_workers(ch_size, ch_size)

    @everywhere struct MakeWorkerError <: PH.Message end

    PH._send_message(worker_inf, first(workers()), MakeWorkerError())

    my_task = @async begin
        PH._wait_for_shutdown(worker_inf)
    end
    if timeout_wait(my_task)
        @test istaskfailed(my_task)
        @test typeof(my_task.exception) <: RemoteException
    else
        error("Timed out on test")
    end

    my_task = @async begin
        PH._wait_for_shutdown(worker_inf)
        return PH._isrunning(worker_inf)
    end
    if timeout_wait(my_task)
        @test !fetch(my_task)
    else
        error("Timed out on test")
    end
end

@testset "Distributed solve" begin
    
    # Solve the problem
    (n, err, obj, soln, phd) = PH.solve(build_scen_tree(),
                                        create_model,
                                        r,
                                        atol=atol,
                                        rtol=rtol,
                                        opt=Ipopt.Optimizer,
                                        opt_args=(print_level=0,tol=1e-12),
                                        max_iter=max_iter,
                                        report=0,
                                        timing=false,
                                        warm_start=true)

    @test err < atol
    @test isapprox(obj, obj_val)
    @test n < max_iter

    for row in eachrow(soln)
        var = row[:variable] * "_{" * row[:scenarios] * "}"
        @test isapprox(row[:value], var_vals[var], atol=1e-7)
    end

end

# Tear down distrbuted stuff
Distributed.rmprocs(Distributed.workers())
@assert Distributed.nprocs() == 1
