[![CI](https://github.com/NREL/ProgressiveHedging.jl/workflows/CI/badge.svg)](https://github.com/NREL/ProgressiveHedging.jl/workflows/master-tests.yml)
[![codecov](https://codecov.io/gh/NREL/ProgressiveHedging.jl/branch/master/graph/badge.svg?token=U9LUA882IM)](https://codecov.io/gh/NREL/ProgressiveHedging.jl)
[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://NREL.github.io/ProgressiveHedging.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://NREL.github.io/ProgressiveHedging.jl/dev)

ProgressiveHedging.jl is a basic implementation of the [Progressive Hedging algorithm](https://pdfs.semanticscholar.org/4ab8/028748c89b226fd46cf9f45de88218779572.pdf) which is used to solve stochastic programs.

ProgressiveHedging.jl makes use of the [JuMP](https://github.com/JuliaOpt/JuMP.jl) framework to build and solve the subproblems.  It can be used with Julia's Distributed package to solve problems in parallel.

See the [documentation](https://NREL.github.io/ProgressiveHedging.jl/stable) or the examples directory for examples.
