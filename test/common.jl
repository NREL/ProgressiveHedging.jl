
function variable_dict()
    first_stage_vars = ["x[1]", "x[2]", "x[3]"]
    second_stage_vars = ["y"]
    third_stage_vars = ["z[1]", "z[2]"]

    var_dict = Dict(1=>first_stage_vars,
                    2=>second_stage_vars,
                    3=>third_stage_vars)
    return var_dict
end

@everywhere function create_model(scenario_id::Int; opt=()->Ipopt.Optimizer(print_level=0))

    model = JuMP.Model(opt)
    
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
    
    JuMP.@variable(model, x[1:3] >= 0.0)
    JuMP.@constraint(model, x[3] <= 1.0)
    obj = zero(JuMP.GenericQuadExpr{Float64,JuMP.VariableRef})
    JuMP.add_to_expression!(obj, sum(c.*x))

    # Second stage
    if scenario_id < 2
        JuMP.@variable(model, y >= 0.0)
        JuMP.@constraint(model, α*sum(x) + β*y >= s1)
        JuMP.add_to_expression!(obj, d*y)
    else
        JuMP.@variable(model, y >= 0.0)
        JuMP.@constraint(model, α*sum(x) + β*y >= s2)
        JuMP.add_to_expression!(obj, d*y)
    end

    # Third stage
    if scenario_id == 0
        JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s11)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))
        
    elseif scenario_id == 1
        JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s12)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))

    elseif scenario_id == 2
        JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s21)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))

    else
        JuMP.@variable(model, z[1:2])
        JuMP.@constraint(model, ϵ*sum(x) + γ*y + δ*sum(z) == s22)
        JuMP.add_to_expression!(obj, a*sum(z[i]^2 for i in 1:2))
    end

    JuMP.@objective(model, Min, obj)
    
    return model
end

function build_scen_tree()

    probs = [0.5*0.75, 0.5*0.25, 0.5*0.75, 0.5*0.25]
    
    tree = PH.ScenarioTree()
    
    for k in 1:2
        node2 = PH.add_node(tree, tree.root)
        for l in 1:2
            PH.add_leaf(tree, node2, probs[(k-1)*2 + l])
        end
    end
    return tree
end

@everywhere function optimizer()
    return Ipopt.Optimizer(print_level=0,
                           tol=1e-12)
end
