
@testset "Invalid Scenario Tree Checks" begin
    st = PH.ScenarioTree()
    PH.add_node(st, root(st))
    PH.add_node(st, root(st))

    @test_throws(ErrorException,
                 PH.solve_extensive(st, two_stage_model, ()->Ipopt.Optimizer()),
                 )
    @test_throws(ErrorException,
                 PH.solve(st, two_stage_model, PH.ScalarPenaltyParameter(2.0))
                 )
end

@testset "Probability Checks" begin
    st = PH.ScenarioTree()
    PH.add_leaf(st, root(st), 0.25)
    PH.add_leaf(st, root(st), 0.5)

    @test_throws(ErrorException,
                 PH.solve_extensive(st, two_stage_model, ()->Ipopt.Optimizer())
                 )
    @test_throws(ErrorException,
                 PH.solve(st, two_stage_model, PH.ScalarPenaltyParameter(2.0))
                 )

    st = PH.ScenarioTree()
    PH.add_leaf(st, root(st), 0.25)
    PH.add_leaf(st, root(st), 0.5)
    PH.add_leaf(st, root(st), 0.5)

    @test_throws(ErrorException,
                 PH.solve_extensive(st, two_stage_model, ()->Ipopt.Optimizer())
                 )
    @test_throws(ErrorException,
                 PH.solve(st, two_stage_model, PH.ScalarPenaltyParameter(2.0))
                 )
end
