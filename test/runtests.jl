
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

@testset "Utils" begin
    include("test_utils.jl")
end
@testset "JuMP Subproblem" begin
    include("test_jumpsp.jl")
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
