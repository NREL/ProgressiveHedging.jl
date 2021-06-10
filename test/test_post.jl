
atol = 1e-8
rtol = 1e-16
max_iter = 500
r = PH.ScalarPenaltyParameter(25.0)

@testset "Residuals" begin
    (n, err, rerr, obj, soln, phd) = PH.solve(build_scen_tree(),
                                              create_model,
                                              r,
                                              opt=Ipopt.Optimizer,
                                              opt_args=(print_level=0,tol=1e-12),
                                              atol=atol,
                                              rtol=rtol,
                                              max_iter=max_iter,
                                              report=0,
                                              save_residuals=1,
                                              timing=false,
                                              warm_start=false)

    res_df = residuals(phd)
    @test size(res_df,1) == n + 1
    rid = n + 1
    @test res_df[rid, :iteration] == n
    @test res_df[rid, :absolute] == err
    @test res_df[rid, :relative] == rerr
end

@testset "Iterates" begin
    (n, err, rerr, obj, soln, phd) = PH.solve(build_scen_tree(),
                                              create_model,
                                              r,
                                              opt=Ipopt.Optimizer,
                                              opt_args=(print_level=0,tol=1e-12),
                                              atol=atol,
                                              rtol=rtol,
                                              max_iter=max_iter,
                                              report=0,
                                              save_iterates=1,
                                              timing=false,
                                              warm_start=false)

    rid = n + 1

    xhat_df = retrieve_xhat_history(phd)
    @test size(xhat_df,1) == n + 1
    @test xhat_df[rid, :iteration] == n
    for (k,var) in enumerate(soln[:,:variable])
        if soln[k,:stage] < 3
            vname = var * "_" * soln[k,:scenarios]
            @test xhat_df[rid, vname] == soln[k, :value]
        end
    end

    x_hist_df = retrieve_no_hat_history(phd)
    x_df = retrieve_no_hats(phd)
    @test size(x_hist_df,1) == n + 1
    @test x_hist_df[rid, :iteration] == n
    for (k,var) in enumerate(x_df[:,:variable])
        if x_df[k,:stage] < 3
            vname = var * "_" * string(x_df[k,:scenario])
            @test x_hist_df[rid, vname] == x_df[k,:value]
        end
    end

    w_hist_df = retrieve_w_history(phd)
    w_df = retrieve_w(phd)
    @test size(w_hist_df,1) == n + 1
    @test w_hist_df[rid, :iteration] == n
    for (k,var) in enumerate(w_df[:,:variable])
        vname = var * "_" * string(w_df[k,:scenario])
        @test w_hist_df[rid, vname] == w_df[k,:value]
    end
end

@testset "Reporting" begin
    global n, err, rerr, obj, soln, phd

    reports = @capture_out((n, err, rerr, obj, soln, phd) = PH.solve(build_scen_tree(),
                                                                     create_model,
                                                                     r,
                                                                     opt=Ipopt.Optimizer,
                                                                     opt_args=(print_level=0,
                                                                               tol=1e-12),
                                                                     atol=atol,
                                                                     rtol=rtol,
                                                                     max_iter=max_iter,
                                                                     report=1,
                                                                     lower_bound=1,
                                                                     save_residuals=1,
                                                                     timing=false,
                                                                     warm_start=false)
                           )

    report_rex = r"Iter:\s*(\d+)\s*AbsR:\s*(\d\.\d+e[+-]\d+)\s*RelR:\s*(\d\.\d+e[+-]\d+)\s*Xhat:\s*(\d\.\d+e[+-]\d+)\s*X:\s*(\d\.\d+e[+-]\d+)"
    bound_rex = r"Iter:\s*(\d+)\s*Bound:\s*(-?\d\.\d+e[+-]\d+)\s*Abs Gap:\s*(\d\.\d+e[+-]\d+)\s*Rel Gap:\s*((\d)+\.\d+(e[+-]\d+)?)"

    res_df = residuals(phd)
    lb_df = lower_bounds(phd)
    N = 5 # number of consensus variables

    nreps = 0
    nbds = 0

    for line in split(reports,"\n")

        if occursin(report_rex, line)

            nreps += 1
            if nreps == Int(floor(n/2))
                m = match(report_rex, line)
                iter = parse(Int, m.captures[1])
                abs = parse(Float64, m.captures[2])
                @test isapprox(res_df[iter + 1, :absolute], abs, rtol=1e-6)
                rel = parse(Float64, m.captures[3])
                @test isapprox(res_df[iter + 1, :relative], rel, rtol=1e-6)
                xhat = parse(Float64, m.captures[4])
                @test isapprox(res_df[iter + 1, :xhat_sq], xhat^2 * N, rtol=1e-6)
                x = parse(Float64, m.captures[5])
                @test isapprox(res_df[iter + 1, :x_sq], x^2 * N, rtol=1e-6)
            end

        elseif occursin(bound_rex, line)

            nbds += 1
            if nbds == Int(floor(n/2))
                m = match(bound_rex, line)
                iter = parse(Int, m.captures[1])
                bound = parse(Float64, m.captures[2])
                @test isapprox(lb_df[iter + 1, "bound"], bound, rtol=1e-3)
                abs = parse(Float64, m.captures[3])
                @test isapprox(lb_df[iter + 1, "absolute gap"], abs, rtol=1e-3)
                rel = parse(Float64, m.captures[4])
                @test isapprox(lb_df[iter + 1, "relative gap"], rel, rtol=1e-3)
            end

        end
    end

    @test nreps == n + 1
    @test nbds == n + 1
end

@testset "Timing" begin
    global n, err, rerr, obj, soln, phd
    reports = @capture_out((n, err, rerr, obj, soln, phd) = PH.solve(build_scen_tree(),
                                                                     create_model,
                                                                     r,
                                                                     opt=Ipopt.Optimizer,
                                                                     opt_args=(print_level=0,
                                                                               tol=1e-12),
                                                                     atol=atol,
                                                                     rtol=rtol,
                                                                     max_iter=max_iter,
                                                                     report=1,
                                                                     save_residuals=1,
                                                                     timing=false,
                                                                     warm_start=false)
                           )
    @test length(reports) > 1
    
end
