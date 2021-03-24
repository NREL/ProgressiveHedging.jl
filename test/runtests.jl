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

include("common.jl")

@testset "Scenario Tree" begin
    include("test_tree.jl")
end
@testset "Sanity Checks" begin
    include("test_sanity.jl")
end
@testset "Utils" begin
    include("test_utils.jl")
end
@testset "JuMP Subproblem" begin
    include("test_jumpsp.jl")
end
@testset "Workers" begin
    include("test_worker.jl")
end
@testset "Penalty Parameters" begin
    include("test_penalty.jl")
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
