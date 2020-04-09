
const NODE_ID = Int
const SCENARIO_ID = Int
const STAGE_ID = Int
const INDEX = Int

"""
Unique identifier for a `ScenarioNode` in a `ScenarioTree`.
"""
struct NodeID
    value::NODE_ID
end
_value(nid::NodeID)::NODE_ID = nid.value
Base.isless(a::NodeID, b::NodeID) = _value(a) < _value(b)

"""
Unique identifier for a scenario.
"""
struct ScenarioID
    value::SCENARIO_ID
end
_value(scid::ScenarioID)::SCENARIO_ID = scid.value
Base.isless(a::ScenarioID, b::ScenarioID) = _value(a) < _value(b)

"""
Unique identifier for a stage.
"""
struct StageID
    value::STAGE_ID
end
_value(sid::StageID)::STAGE_ID = sid.value
_increment(sid::StageID)::StageID = StageID(_value(sid) + one(STAGE_ID))
Base.isless(a::StageID, b::StageID) = _value(a) < _value(b)

"""
Unique identifier for variables associated with the same scenario tree node.
"""
struct Index
    value::INDEX
end
_value(idx::Index)::INDEX = idx.value
_increment(index::Index)::Index = Index(_value(index) + one(INDEX))
Base.isless(a::Index, b::Index) = _value(a) < _value(b)

"""
Unique identifier for any variable in a (multi-stage) stochastic programming problem.  Composed of a `ScenarioID`, a `StageID` and an `Index`.
"""
struct VariableID
    scenario::ScenarioID # scenario to which this variable belongs
    stage::StageID # stage to which this variable belongs
    index::Index # coordinate in vector
end


"""
Returns the `ScenarioID` of the specified `VariableID`.
"""
function scenario(vid::VariableID)::ScenarioID
    return vid.scenario
end

"""
Returns the `StageID` of the specified `VariableID`.
"""
function stage(vid::VariableID)::StageID
    return vid.stage
end

"""
Returns the `Index` of the specified `VariableID`.
"""
function index(vid::VariableID)::Index
    return vid.index
end

function Base.isless(a::VariableID, b::VariableID)
    return (a.stage < b.stage ||
            (a.stage == b.stage &&
             (a.scenario < b.scenario ||
              (a.scenario == b.scenario && a.index < b.index))))
end

"""
Unique identifier for hat variables.  Used internally by PH.
"""
struct XhatID
    node::NodeID
    index::Index
end

function Base.isless(a::XhatID, b::XhatID)
    return (a.node < b.node ||
            (a.node == b.node && a.index < b.index))
end
