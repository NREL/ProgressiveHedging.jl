
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

@testset "Extensive form" begin
    sjm = build_sj_model()

    efm = PH.solve_extensive_form(sjm, optimizer())
    @test isapprox(JuMP.objective_value(efm), obj_val)
    for var in JuMP.all_variables(efm)
        @test isapprox(JuMP.value(var), var_vals[JuMP.name(var)])
    end
end

@testset "StructJuMP solve" begin
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
end

@testset "StructJuMP tree solve" begin
    sjm = build_sj_tree()
    (n, err, obj, soln, phd) = PH.solve(PH.build_scenario_tree(sjm),
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

@testset "Direct tree solve" begin
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

@testset "Max iteration termination" begin
    max_iter = 4
    regex = r".*"
    @info "Ignore the following warning."
    (n, err, obj, soln, phd) = @test_warn(regex,
                                          PH.solve(build_scen_tree(),
                                                   create_model,
                                                   variable_dict(),
                                                   optimizer(),
                                                   r,
                                                   atol=atol,
                                                   max_iter=max_iter,
                                                   report=false,
                                                   timing=false)
                                          )
    @test n == max_iter
end
