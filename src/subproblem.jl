
abstract type AbstractSubproblem end

struct UnimplementedError <: Exception
    msg::String
end

function add_variable(as::S,
                      vi::JuMP.VariableInfo
                      )::JuMP.VariableRef where {S <: AbstractSubproblem}
    throw(UnimplementedError("add_variable is unimplemented for $(S)"))
end

function objective(as::S)::JuMP.VariableRef where {S <: AbstractSubproblem}
    throw(UnimplementedError("objective is unimplemented for $(S)"))
end

function objective_value(as::S)::Float64 where {S <: AbstractSubproblem}
    throw(UnimplementedError("objective_value is unimplemented for $(S)"))
end

function set_objective(as::S)::Nothing where {S <: AbstractSubproblem}
    throw(UnimplementedError("set_objective is unimplemented for $(S)"))
end

function variable_by_name(as::S,
                          name::String
                          )::V where {S <: AbstractSubproblem,
                                      V <: JuMP.AbstractVariableRef}
    throw(UnimplementedError("variable_by_name is unimplemented for $(S)"))
end

function variable_type(as::S
                       )::V where {S <: AbstractSubproblem,
                                   V <: JuMP.AbstractVariableRef}
    throw(UnimplementedError("variable_type is unimplemented for $(S)"))
end

function solve(as::S)::MOI.TerminationStatusCode where {S <: AbstractSubproblem}
    throw(UnimplementedError("solve is unimplemented for $(S)"))
end

function warm_start(as::S)::Nothing where {S <: AbstractSubproblem}
    throw(UnimplementedError("warm_start is unimplemented for $(S)"))
end

struct JuMPSubproblem <: AbstractSubproblem
    model::JuMP.Model
end

function _error(astring::String)
    return
end

function add_variable(js::JuMPSubproblem, vi::JuMP.VariableInfo)::JuMP.VariableRef
    return JuMP.add_variable(js.model, JuMP.build_variable(_error, vi))
end

function objective(js::JuMPSubproblem)
    return JuMP.objective_function(js.model,
                                   JuMP.GenericQuadExpr{Float64, JuMP.variable_type(js.model)}
                                   )
end

function objective_value(js::JuMPSubproblem)::Float64
    return JuMP.objective_value(js.model)
end

function set_objective(js::JuMPSubproblem,
                       obj::JuMP.GenericQuadExpr{Float64,V}
                       )::Nothing where {V <: JuMP.AbstractVariableRef}
    JuMP.set_objective_function(js.model, obj)
    return
end

function variable_by_name(js::JuMPSubproblem, name::String)::JuMP.VariableRef
    return JuMP.variable_by_name(js.model, name)
end

function variable_type(js::JuMPSubproblem)
    return JuMP.variable_type(js.model)
end

function solve(js::JuMPSubproblem)::MOI.TerminationStatusCode
    JuMP.optimize!(js.model)
    return JuMP.termination_status(js.model)
end

# function termination_status(js::JuMPSubproblem)::MOI.TerminationStatusCode
#     return JuMP.termination_status(js.model)
# end

function warm_start(js::JuMPSubproblem)::Nothing
    for var in JuMP.all_variables(js.model)
        if !JuMP.is_fixed(var)
            JuMP.set_start_value(var, JuMP.value(var))
        end
    end
    return
end
