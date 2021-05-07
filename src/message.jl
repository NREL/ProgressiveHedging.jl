
abstract type Message end

struct Abort <: Message end

struct Initialize{R <: AbstractPenaltyParameter} <: Message
    create_subproblem::Function
    create_subproblem_args::Tuple
    create_subproblem_kwargs::NamedTuple
    r::Type{R}
    scenarios::Set{ScenarioID}
    scenario_tree::ScenarioTree
    warm_start::Bool
    subproblem_callbacks::Vector{SubproblemCallback}
end

struct PenaltyInfo <: Message
    scen::ScenarioID
    penalty::Union{Float64,Dict{VariableID,Float64}}
end

struct Ping <: Message end

struct ReportBranch <: Message
    scen::ScenarioID
    sts::MOI.TerminationStatusCode
    obj::Float64
    time::Float64
    vals::Dict{VariableID,Float64}
end

struct ReportLeaf <: Message
    scen::ScenarioID
    vals::Dict{VariableID,Float64}
end

struct ShutDown <: Message end

struct Solve <: Message
    scen::ScenarioID
    w_vals::Dict{VariableID,Float64}
    xhat_vals::Dict{VariableID,Float64}
end

struct SubproblemAction <: Message
    scen::ScenarioID
    action::Function
    args::Tuple
    kwargs::NamedTuple
end

struct VariableMap <: Message
    scen::ScenarioID
    var_info::Dict{VariableID,VariableInfo} # VariableInfo definition in subproblem.jl
end
