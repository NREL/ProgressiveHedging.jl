
abstract type Message end

struct Abort <: Message end

struct Initialize{R <: AbstractPenaltyParameter} <: Message
    create_subproblem::Function
    create_subproblem_args::Tuple
    create_subproblem_kwargs::NamedTuple
    r::R
    scenarios::Set{ScenarioID}
    scenario_tree::ScenarioTree
    warm_start::Bool
end

struct PenaltyMap <: Message
    scen::ScenarioID
    var_penalties::Dict{VariableID,Float64}
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

struct Solve <: Message
    scen::ScenarioID
    w_vals::Dict{VariableID,Float64}
    xhat_vals::Dict{VariableID,Float64}
end

struct ShutDown <: Message end

struct VariableMap <: Message
    scen::ScenarioID
    var_names::Dict{VariableID,String}
end
