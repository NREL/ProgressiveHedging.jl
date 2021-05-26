
using Pkg
Pkg.activate("..")

using Documenter
using ProgressiveHedging

makedocs(modules=[ProgressiveHedging],
         format=Documenter.HTML(prettyurls=haskey(ENV,"GITHUB_ACTIONS")),
         sitename="ProgressiveHedging.jl",
         authors="Jonathan Maack",
         pages=["Overview" => "index.md",
                "API" => "api.md"
                ]
         )
