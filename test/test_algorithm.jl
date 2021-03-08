
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

@testset "Solve Extensive" begin
    efm = PH.solve_extensive(build_scen_tree(),
                             create_model,
                             ()->Ipopt.Optimizer();
                             opt_args=(print_level=0,tol=1e-12)
                             )

    @test JuMP.num_variables(efm) == length(keys(var_vals))

    cnum = 0
    for (f,s) in JuMP.list_of_constraint_types(efm)
        cnum += JuMP.num_constraints(efm, f, s)
    end
    @test cnum == 12

    @test JuMP.termination_status(efm) == MOI.LOCALLY_SOLVED
    @test isapprox(JuMP.objective_value(efm), obj_val)

    for var in JuMP.all_variables(efm)
        @test isapprox(JuMP.value(var), var_vals[JuMP.name(var)])
    end

    struct FakeSubproblem <: AbstractSubproblem end
    fake_constructor(scen::Int) = FakeSubproblem()
    @test_throws(ProgressiveHedging.UnimplementedError,
                 PH.solve_extensive(build_scen_tree(),
                                    fake_constructor,
                                    ()->Ipopt.Optimizer(),
                                    subproblem_type=FakeSubproblem)
                 )
end

@testset "Solve" begin
    (n, err, obj, soln, phd) = PH.solve(build_scen_tree(),
                                        create_model,
                                        r,
                                        opt=Ipopt.Optimizer,
                                        opt_args=(print_level=0,tol=1e-12),
                                        atol=atol,
                                        rtol=rtol,
                                        max_iter=max_iter,
                                        report=0,
                                        timing=false,
                                        warm_start=false)

    @test err < atol
    @test isapprox(obj, obj_val)
    @test n < max_iter

    for row in eachrow(soln)
        var = row[:variable] * "_{" * row[:scenarios] * "}"
        @test isapprox(row[:value], var_vals[var], atol=1e-7)
    end

    (n, err, obj, soln, phd) = PH.solve(build_scen_tree(),
                                        create_model,
                                        PH.ProportionalPenaltyParameter(10),
                                        opt=Ipopt.Optimizer,
                                        opt_args=(print_level=0,tol=1e-12),
                                        atol=atol,
                                        rtol=rtol,
                                        max_iter=max_iter,
                                        report=0,
                                        timing=false,
                                        warm_start=false
                                        )

    # @test err < atol
    # @test isapprox(obj, obj_val)
    # @test n < max_iter

    # for row in eachrow(soln)
    #     var = row[:variable] * "_{" * row[:scenarios] * "}"
    #     @test isapprox(row[:value], var_vals[var], atol=1e-7)
    # end

end

@testset "Warm-start" begin
    (n, err, obj, soln, phd) = PH.solve(build_scen_tree(),
                                        create_model,
                                        r,
                                        opt=Ipopt.Optimizer,
                                        opt_args=(print_level=0,tol=1e-12),
                                        atol=atol,
                                        rtol=rtol,
                                        max_iter=max_iter,
                                        report=-5,
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

@testset "Max iteration termination" begin
    max_iter = 4
    regex = r".*"
    @info "Ignore the following warning."
    (n, err, obj, soln, phd) = @test_warn(regex,
                                          PH.solve(build_scen_tree(),
                                                   create_model,
                                                   r,
                                                   opt=Ipopt.Optimizer,
                                                   opt_args=(print_level=0,tol=1e-12),
                                                   atol=atol,
                                                   rtol=rtol,
                                                   max_iter=max_iter,
                                                   report=0,
                                                   timing=false)
                                          )
    @test err > atol
    @test n == max_iter
end

@testset "Relative tolerance termination" begin
    rtol = 1e-6
    (n, err, obj, soln, phd) = PH.solve(build_scen_tree(),
                                        create_model,
                                        r,
                                        opt=Ipopt.Optimizer,
                                        opt_args=(print_level=0,tol=1e-12),
                                        atol=atol,
                                        rtol=rtol,
                                        max_iter=max_iter,
                                        report=0,
                                        timing=false,
                                        warm_start=true)

    xmax = maximum(soln[soln[:,:stage] .!= 3,:value])
    @test err > atol
    @test n < max_iter
    @test err < rtol * xmax
end
