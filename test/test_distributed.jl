
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
    
    # Solve the problem with StructJuMP interface
    sjm = build_sj_model()
    (n, err, obj, soln, phd) = PH.solve(sjm,
                                        optimizer(),
                                        r, atol=atol, max_iter=max_iter,
                                        report=false, timing=false)
    @test err < atol
    @test isapprox(obj, obj_val)
    @test n < max_iter
    for row in eachrow(soln)
        @test isapprox(row[:value], var_vals[row[:variable]], atol=1e-7)
    end

    # Solve the problem with scenario tree interface
    (n, err, obj, soln, phd) = PH.solve(build_scen_tree(),
                                        create_model,
                                        variable_dict(),
                                        optimizer(),
                                        r,
                                        atol=atol,
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
