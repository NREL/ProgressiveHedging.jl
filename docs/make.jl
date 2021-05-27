
using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "examples"))

using Documenter
using ProgressiveHedging

makedocs(modules=[ProgressiveHedging],
         format=Documenter.HTML(prettyurls=haskey(ENV,"GITHUB_ACTIONS")),
         sitename="ProgressiveHedging.jl",
         authors="Jonathan Maack",
         pages=["Overview" => "index.md",
                "Examples" => map(s -> "examples/$(s)",
                                  sort(readdir(joinpath(@__DIR__, "src", "examples")))
                                  ),
                "Reference" => map(s -> "api/$(s)",
                                   sort(readdir(joinpath(@__DIR__, "src", "api")))
                                   ),
                ]
         )
