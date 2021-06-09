
using Pkg
Pkg.activate(@__DIR__)

using ProgressiveHedging
import JuMP
import Ipopt

function create_model(scenario_id::ScenarioID)
    
    model = JuMP.Model(()->Ipopt.Optimizer())
    JuMP.set_optimizer_attribute(model, "print_level", 0)
    JuMP.set_optimizer_attribute(model, "tol", 1e-12)
    
    c = [1.0, 10.0, 0.01]
    d = 7.0
    a = 16.0

    α = 1.0
    β = 1.0
    γ = 1.0
    δ = 1.0
    ϵ = 1.0

    s1 = 8.0
    s2 = 4.0
    s11 = 9.0
    s12 = 16.0
    s21 = 5.0
    s22 = 18.0
    
    stage1 = JuMP.@variable(model, x[1:3] >= 0.0)
    JuMP.@constraint(model, x[3] <= 1.0)
    obj = zero(JuMP.GenericQuadExpr{Float64,JuMP.VariableRef})
    JuMP.add_to_expression!(obj, sum(c.*x))

    # Second stage
    stage2 = Vector{JuMP.VariableRef}()
    if scenario_id < scid(2)
        vref = JuMP.@variable(model, y >= 0.0)
        JuMP.@constraint(model, α*sum(x) + β*y >= s1)
        JuMP.add_to_expression!(obj, d*y)
    else
        vref = JuMP.@variable(model, y >= 0.0)
        JuMP.@constraint(model, α*sum(x) + β*y >= s2)
        JuMP.add_to_expression!(obj, d*y)
    end
    push!(stage2, vref)

    # Third stage
    stage3 = Vector{JuMP.VariableRef}()
    if scenario_id == scid(0)
        vref = JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s11)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))
        
    elseif scenario_id == scid(1)
        vref = JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s12)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))

    elseif scenario_id == scid(2)
        vref = JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s21)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))

    else
        vref = JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s22)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))
    end
    append!(stage3, vref)

    JuMP.@objective(model, Min, obj)
    
    vdict = Dict{StageID, Vector{JuMP.VariableRef}}([stid(1) => stage1,
                                                        stid(2) => stage2,
                                                        stid(3) => stage3,
                                                        ])
    
    return JuMPSubproblem(model, scenario_id, vdict)
end

scen_tree = ScenarioTree()
branch_node_1 = add_node(scen_tree, root(scen_tree))
branch_node_2 = add_node(scen_tree, root(scen_tree))

add_leaf(scen_tree, branch_node_1, 0.375)
add_leaf(scen_tree, branch_node_1, 0.125)

add_leaf(scen_tree, branch_node_2, 0.375)
add_leaf(scen_tree, branch_node_2, 0.125)

(niter, abs_res, rel_res, obj, soln_df, phd) = solve(scen_tree,
                                                     create_model,
                                                     ScalarPenaltyParameter(25.0);
                                                     atol=1e-8, rtol=1e-12, max_iter=500)
@show niter
@show abs_res
@show rel_res
@show obj
@show soln_df

