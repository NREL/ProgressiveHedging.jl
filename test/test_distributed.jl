
r = 25.0
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
Distributed.addprocs(2)
@everywhere using Pkg
@everywhere Pkg.activate(".")
@everywhere using ProgressiveHedging
@everywhere using Ipopt
@everywhere using JuMP
include("common.jl")

@assert Distributed.nworkers() == 2

@testset "Distributed solve" begin
    
    # Solve the problem
    (n, err, obj, soln, phd) = PH.solve(build_scen_tree(),
                                        create_model,
                                        variable_dict(),
                                        r,
                                        atol=atol,
                                        rtol=rtol,
                                        opt=optimizer,
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
