using Pkg

using ProgressiveHedging
const PH = ProgressiveHedging

using Test

using Distributed

using Ipopt
using JuMP
using MathOptInterface
const MOI = MathOptInterface

using TimerOutputs

macro optional_using(pkg)
    quote
        try
            using $pkg
        catch e
            if typeof(e) != ArgumentError
                rethrow(e)
            end
        end
    end
end

@optional_using(Xpress)

include("common.jl")

@testset "ProgressiveHedging" begin
    @testset "Scenario Tree" begin
        include("test_tree.jl")
    end
    @testset "Sanity Checks" begin
        include("test_sanity.jl")
    end
    @testset "Utils" begin
        include("test_utils.jl")
    end
    @testset "Subproblem" begin
        include("test_subproblem.jl")
    end
    @testset "Workers" begin
        include("test_worker.jl")
    end
    @testset "Penalty Parameters" begin
        include("test_penalty.jl")
    end
    @testset "Callbacks" begin
        include("test_callback.jl")
    end
    @testset "Setup" begin
        include("test_setup.jl")
    end
    @testset "Algorithm" begin
        include("test_algorithm.jl")
    end
    @testset "Distributed" begin
        include("test_distributed.jl")
    end
end
