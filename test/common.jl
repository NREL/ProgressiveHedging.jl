
function variable_dict()
    first_stage_vars = ["x[1]", "x[2]", "x[3]"]
    second_stage_vars = ["y"]
    third_stage_vars = ["z[1]", "z[2]"]

    var_dict = Dict(1=>first_stage_vars,
                    2=>second_stage_vars,
                    3=>third_stage_vars)
    return var_dict
end

@everywhere function create_model(scenario_id::Int, model::M
        )::M where M <: JuMP.AbstractModel
    
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

function build_sj_tree()
    nscen = 4
    nbranch = 2

    # First stage
    root_model = StructuredModel(num_scenarios=nbranch)

    # Second stage
    mid_model_1 = StructuredModel(parent=root_model, id=1, num_scenarios=nbranch,
                                  prob=0.5)
    mid_model_2 = StructuredModel(parent=root_model, id=2, num_scenarios=nbranch,
                                  prob=0.5)

    # Third stage
    leaf_11 = StructuredModel(parent=mid_model_1, id=11, prob=0.75)
    leaf_12 = StructuredModel(parent=mid_model_1, id=12, prob=0.25)
    leaf_21 = StructuredModel(parent=mid_model_2, id=21, prob=0.75)
    leaf_22 = StructuredModel(parent=mid_model_2, id=22, prob=0.25)

    return root_model
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

function build_sj_model()
    nscen = 4
    nbranch = 2
    # Parameters
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

    # First stage
    root_model = StructuredModel(num_scenarios=nbranch)
    @variable(root_model, x[1:3] >= 0.0)
    #@variable(root_model, F >= 0.0)
    @objective(root_model, Min, sum(c.*x))
    @constraint(root_model, x[3] <= 1.0)

    # Second stage
    mid_model_1 = StructuredModel(parent=root_model, id=1, num_scenarios=nbranch, prob=0.5)
    @variable(mid_model_1, y1 >= 0.0)
    @objective(mid_model_1, Min, d*y1)
    @constraint(mid_model_1, α*sum(x) + β*y1 >= s1)
    mid_model_2 = StructuredModel(parent=root_model, id=2, num_scenarios=nbranch, prob=0.5)
    @variable(mid_model_2, y2 >= 0.0)
    @objective(mid_model_2, Min, d*y2)
    @constraint(mid_model_2, α*sum(x) + β*y2 >= s2)

    # Third stage
    leaf_11 = StructuredModel(parent=mid_model_1, id=11, prob=0.75)
    # @variable(leaf_11, z11 >= 0.0)
    @variable(leaf_11, z11[1:2])
    @objective(leaf_11, Min, a*sum(z11[i]^2 for i in 1:2))
    @constraint(leaf_11, ϵ*sum(x) + γ*y1 + δ*sum(z11) == s11)

    leaf_12 = StructuredModel(parent=mid_model_1, id=12, prob=0.25)
    # @variable(leaf_12, z12 >= 0.0)
    @variable(leaf_12, z12[1:2])
    @objective(leaf_12, Min, a*sum(z12[i]^2 for i in 1:2))
    @constraint(leaf_12, ϵ*sum(x) + γ*y1 + δ*sum(z12) == s12)

    leaf_21 = StructuredModel(parent=mid_model_2, id=21, prob=0.75)
    # @variable(leaf_21, z21 >= 0.0)
    @variable(leaf_21, z21[1:2])
    @objective(leaf_21, Min, a*sum(z21[i]^2 for i in 1:2))
    @constraint(leaf_21, ϵ*sum(x) + γ*y2 + δ*sum(z21) == s21)

    leaf_22 = StructuredModel(parent=mid_model_2, id=22, prob=0.25)
    # @variable(leaf_22, z22 >= 0.0)
    @variable(leaf_22, z22[1:2])
    @objective(leaf_22, Min, a*sum(z22[i]^2 for i in 1:2))
    @constraint(leaf_22, ϵ*sum(x) + γ*y2 + δ*sum(z22) == s22)
    
    return root_model
end

function optimizer()
    return with_optimizer(Ipopt.Optimizer,
                          print_level=0,
                          tol=1e-12)
end
