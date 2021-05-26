
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

@testset "Error Handling" begin
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
        return PH._is_running(worker_inf)
    end
    if timeout_wait(my_task)
        @test !fetch(my_task)
    else
        error("Timed out on test")
    end
end

@testset "Solve" begin
    
    # Solve the problem
    (n, err, rerr, obj, soln, phd) = PH.solve(build_scen_tree(),
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

@testset "User Specified Workers" begin

    st = build_scen_tree()
    worker_assignments = Dict(k=>Set{PH.ScenarioID}() for k in 2:3)
    for s in PH.scenarios(st)
        if PH.value(s) < 3
            push!(worker_assignments[2], s)
        else
            push!(worker_assignments[3], s)
        end
    end
    
    # Solve the problem
    (n, err, rerr, obj, soln, phd) = PH.solve(build_scen_tree(),
                                              create_model,
                                              r;
                                              atol=atol,
                                              rtol=rtol,
                                              opt=Ipopt.Optimizer,
                                              opt_args=(print_level=0,tol=1e-12),
                                              max_iter=max_iter,
                                              report=0,
                                              worker_assignments=worker_assignments,
                                              timing=false,
                                              warm_start=true)

    @test err < atol
    @test isapprox(obj, obj_val)
    @test n < max_iter

    for row in eachrow(soln)
        var = row[:variable] * "_{" * row[:scenarios] * "}"
        @test isapprox(row[:value], var_vals[var], atol=1e-7)
    end

    for s in PH.scenarios(phd)
        if PH.value(s) < 3
            @test phd.scenario_map[s].pid == 2
        else
            @test phd.scenario_map[s].pid == 3
        end
    end

end

@testset "Lower Bound Algorithm" begin
    (n, err, rerr, obj, soln, phd) = PH.solve(PH.two_stage_tree(2),
                                              two_stage_model,
                                              PH.ScalarPenaltyParameter(2.0),
                                              atol=atol,
                                              rtol=rtol,
                                              max_iter=max_iter,
                                              report=0,
                                              lower_bound=5,
                                              timing=false,
                                              warm_start=false
                                              )

    @test err < atol
    @test isapprox(obj, 8.25, atol=1e-6)
    @test n < max_iter

    lb_df = PH.lower_bounds(phd)
    for row in eachrow(lb_df)
        @test row[:bound] <= 8.25
    end

    @test size(lb_df,1) == 12
    @test isapprox(lb_df[size(lb_df,1), "absolute gap"], 0.0, atol=1e-7)
    @test isapprox(lb_df[size(lb_df,1), "relative gap"], 0.0, atol=(1e-7/8.25))
end

# Tear down distrbuted stuff
Distributed.rmprocs(Distributed.workers())
@assert Distributed.nprocs() == 1
