
# ProgressiveHedging.jl

```@meta
CurrentModule = ProgressiveHedging
```

## Overview

ProgressiveHedging.jl is a [Julia](https://julialang.org/) implementation of the [Progressive Hedging](https://pubsonline.informs.org/doi/abs/10.1287/moor.16.1.119) algorithm of Rockafellar and Wets.  It is capable of solving multi-stage stochastic programs:

``\min_X \sum_{s=1}^S p_s f_s(X)``

To solve this problem, it makes use of [JuMP](https://github.com/JuliaOpt/JuMP.jl). Specifically, the user constructs a wrapped JuMP model for a single subproblem as well as a scenario tree which describes the structure of the stochastic program. Through the use of Julia's [Distributed](https://docs.julialang.org/en/v1/stdlib/Distributed/) package, PH may be run in parallel either on a single multi-core platform or in a distributed fashion across multiple compute nodes.

In addition to providing an easily accessible solver for stochastic programs, ProgressiveHedging.jl is designed to be extensible to enable research on the PH algorithm itself.  Abstract interfaces exist for the penalty parameter and subproblem types so that the user may implement their own penalty parameter selection method or use an Julia enabled algebraic modeling language.

------------
ProgressiveHedging has been developed as part of the Scalable Integrated Infrastructure Planning (SIIP) initiative at the U.S. Department of Energy's National Renewable Energy Laboratory ([NREL](https://www.nrel.gov/))