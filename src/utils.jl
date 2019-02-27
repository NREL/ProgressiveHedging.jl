
function get_value(model::M, name::String) where M <: JuMP.AbstractModel
    return JuMP.value(JuMP.variable_by_name(model, name))
end

function get_fix_value(model::M, name::String) where M <: JuMP.AbstractModel
    return JuMP.fix_value(JuMP.variable_by_name(model, name))
end

function stringify_set(set::Set{K}) where K
    str = ""
    for s in sort!(collect(set))
        str *= string(s) * ", "
    end
    return rstrip(str, [',',' '])
end

function retrieve_soln(phd::PHData)

    vars = Vector{String}()
    vals = Vector{Float64}()
    stages = Vector{Int}()
    scens = Vector{String}()
    
    for var in sort!(collect(keys(phd.params.variable_map)))
        info = phd.params.variable_map[var]
        scen = first(info.scenario_bundle)
        push!(vars, var)
        push!(vals, phd.Xhat[Tuple([scen, var])])
        push!(stages, info.stage)
        push!(scens, stringify_set(info.scenario_bundle))
    end
    soln_df = DataFrames.DataFrame(variable=vars, value=vals, stage=stages,
                                   scenarios=scens)
    
    return soln_df
end

function retrieve_obj_value(phd::PHData)
    # TODO: Implement this...
    @warn("Not yet implemented")
    return 0.0
end
