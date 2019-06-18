module ProgressiveHedging

import JuMP
import StructJuMP
import DataFrames

import MathOptInterface
const MOI = MathOptInterface

using Distributed

#export solve

# TODO: Find a way to return the objective value for each scenario

# TODO: Pass in actual error function for adding things in case something
# goes wrong. Currently just a function stub.

include("structs.jl")
include("utils.jl")

include("algorithm.jl")
include("setup.jl")

function solve(root_model::StructJuMP.StructuredModel,
               optimizer_factory::JuMP.OptimizerFactory,
               r::T; model_type::Type{M}=JuMP.Model, max_iter=100, atol=1e-8,
               report=false
               ) where {T <: Number, M <: JuMP.AbstractModel}
    # Initialization
    ph_data = initialize(root_model, r, optimizer_factory, M)
    
    # Solution
    (niter, residual) = hedge(ph_data, max_iter, atol, report)

    # Post Processing
    soln_df = retrieve_soln(ph_data)
    obj = retrieve_obj_value(ph_data)
    
    # return (niter, residual, soln_df, cost_dict, ph_data)
    return (niter, residual, obj, soln_df, ph_data)
end

function solve_extensive_form(root_model::StructJuMP.StructuredModel,
                              optimizer_factory::JuMP.OptimizerFactory;
                              model_type::Type{M}=JuMP.Model, kwargs...
                              ) where {M <: JuMP.AbstractModel}
    model = @spawnat(1, M(kwargs...)) # Always local
    build_extensive_form(root_model, model)
    JuMP.optimize!(fetch(model), optimizer_factory)
    return fetch(model)
end

end # module
