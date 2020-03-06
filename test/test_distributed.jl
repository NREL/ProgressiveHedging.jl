
r = 25.0
atol = 1e-8
max_iter = 500
obj_val = 178.3537498401004
var_vals = Dict([
    "x[1]" => 7.5625,
    "x[2]" => 0.0,
    "x[3]" => 1.0,
    "y1" => 1.75,
    "y2" => 0.0,
    "z11[1]" => -0.65625,
    "z11[2]" => -0.65625,
    "z12[1]" => 2.84375,
    "z12[2]" => 2.84375,
    "z21[1]" => -1.78125,
    "z21[2]" => -1.78125,
    "z22[1]" => 4.71875,
    "z22[2]" => 4.71875,
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
                                        opt=optimizer,
                                        max_iter=max_iter,
                                        report=false,
                                        timing=false)

    @test err < atol
    @test isapprox(obj, obj_val)
    @test n < max_iter

    for row in eachrow(soln)

        var = row[:variable]

        if var == "y"
            if row[:scenarios] == "0, 1"
                var *= string(1)
            elseif row[:scenarios] == "2, 3"
                var *= string(2)
            else
                # Nothing--something is wrong, so fall through and trigger
                # key error in dictionary
            end

        elseif occursin("z", var)

            scen = parse(Int,row[:scenarios])
            nstr = split(var,"[")[2]

            if scen == 0
                var = "z11["
            elseif scen == 1
                var = "z12["
            elseif scen == 2
                var = "z21["
            elseif scen == 3
                var = "z22["
            else
                # Nothing--this is an error
            end

            var *= nstr
        else
            # Nothing
        end
        @test isapprox(row[:value], var_vals[var], atol=1e-7)
    end

end

# Tear down distrbuted stuff
Distributed.rmprocs(Distributed.workers())
@assert Distributed.nprocs() == 1
