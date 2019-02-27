module ProgressiveHedging

using JuMP
using StructJuMP
using DataFrames

# using MathOptInterface
# const MOI = MathOptInterface

export solve

# TODO: Probably should rewrite everything so that scenario keys get mapped onto a
# continuous integer range and then write everything in arrays instead of dicts

# TODO: Come up with better way of tracking variables across models than user given
# names

# TODO: Find a way to return the objective value for each scenario

include("structs.jl")
include("utils.jl")

include("algorithm.jl")
include("setup.jl")

function solve(root_model::StructJuMP.StructuredModel,
               optimizer_factory::JuMP.OptimizerFactory,
               r::T; model_type::Type{M}=JuMP.Model, max_iter=100, atol=1e-8
               ) where {T <: Number, M <: JuMP.AbstractModel}
    # Initialization
    ph_data = initialize(root_model, r, optimizer_factory, M)
    compute_and_save_xhat(ph_data)
    set_start_values(ph_data)
    
    # Solution
    niter = 0
    residual = atol + 1.0e10
    while niter < max_iter && residual > atol
        fix_w(ph_data)
        fix_xhat(ph_data)
        solve_subproblems(ph_data)
        residual = compute_and_save_values(ph_data)
        niter += 1
    end

    if niter >= max_iter
        @warn("Performed $niter iterations without convergence. " *
              "Consider increasing max_iter from $max_iter.")
    end

    # Post Processing
    #(soln_df, cost_dict) = retrieve_soln(ph_data)
    soln_df = retrieve_soln(ph_data)
    
    # return (niter, residual, soln_df, cost_dict, ph_data)
    return (niter, residual, soln_df, ph_data)
end

function build_extensive_form(root_model::StructJuMP.StructuredModel,
                              model::M) where {M <: JuMP.AbstractModel}
    (phii, probs) = extract_structure(root_model)

    vars = Dict{String, StructJuMP.StructuredVariableRef}()
    vmap = Dict{String, VariableInfo{Int}}()

    sj_models = [root_model]
    probs = [1.0]
    obj = GenericAffExpr{Float64, JuMP.variable_type(model)}()
    
    while !isempty(sj_models)
        sjm = pop!(sj_models)
        p = pop!(probs)

        for (id, cmod) in sjm.children
            push!(sj_models, cmod)
            # Here's that Markov assumption again
            push!(probs, p * sjm.probability[id])
        end

        # Adding variables
        new_vars = name_variables(sjm)
        for (name, ref) in pairs(new_vars)
            vi = ref.model.variables[ref.idx].info
            info = JuMP.VariableInfo(vi.has_lb, vi.lower_bound,
                                 vi.has_ub, vi.upper_bound,
                                 vi.has_fix, vi.fixed_value,
                                 vi.has_start, vi.start,
                                 vi.binary, vi.integer)
            JuMP.add_variable(model, JuMP.build_variable(_error, info), name)
        end

        # Adding constraints
        copy_constraints(model, sjm)

        # Building objective function
        obj += p * convert_expression(model, sjm.objective_function)
    end

    # Add objective function
    JuMP.set_objective(model, root_model.objective_sense, obj)

    return model
end

function solve_extensive_form(root_model::StructJuMP.StructuredModel,
                              optimizer_factory::JuMP.OptimizerFactory;
                              model::M=JuMP.Model()
                              ) where {M <: JuMP.AbstractModel}
    build_extensive_form(root_model, model)
    JuMP.optimize!(model, optimizer_factory)
    return model
end

end # module
