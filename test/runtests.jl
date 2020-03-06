
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

include("test_setup.jl")
include("test_algorithm.jl")
include("test_distributed.jl")
