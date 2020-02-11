ProgressiveHedging.jl is a basic implementation of the [Progressive Hedging algorithm](https://pdfs.semanticscholar.org/4ab8/028748c89b226fd46cf9f45de88218779572.pdf) which is used to solve stochastic programs.

ProgressiveHedging.jl makes use of the [JuMP](https://github.com/JuliaOpt/JuMP.jl) framework to build and solve the subproblems.  It can be used with Julia's Distributed package to solve problems in parallel.

Users may build their problem in [StructJuMP](https://github.com/StructJuMP/StructJuMP.jl) (an extension of JuMP for stochastic programming) or pass a function that builds a JuMP model directly.

Examples written in a Jupyter notebook may be found in the Examples directory.

Note that ProgressiveHedging.jl requires the master branch of StructJuMP which can be installed from Julia's package management environment with the command `add StructJuMP#master`.
