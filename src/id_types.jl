
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
value(nid::NodeID)::NODE_ID = nid.value
Base.isless(a::NodeID, b::NodeID) = value(a) < value(b)

"""
Unique identifier for a scenario.
"""
struct ScenarioID
    value::SCENARIO_ID
end
value(scid::ScenarioID)::SCENARIO_ID = scid.value
Base.isless(a::ScenarioID, b::ScenarioID) = value(a) < value(b)

"""
Unique identifier for a stage.
"""
struct StageID
    value::STAGE_ID
end
value(sid::StageID)::STAGE_ID = sid.value
_increment(sid::StageID)::StageID = StageID(value(sid) + one(STAGE_ID))
Base.isless(a::StageID, b::StageID) = value(a) < value(b)

"""
Unique identifier for variables associated with the same scenario tree node.
"""
struct Index
    value::INDEX
end
value(idx::Index)::INDEX = idx.value
_increment(index::Index)::Index = Index(value(index) + one(INDEX))
Base.isless(a::Index, b::Index) = value(a) < value(b)

"""
Unique identifier for any variable in a (multi-stage) stochastic programming problem.  Composed of a `ScenarioID`, a `StageID` and an `Index`.
"""
struct VariableID
    scenario::ScenarioID # scenario to which this variable belongs
    stage::StageID # stage to which this variable belongs
    index::Index # coordinate in vector
end


"""
    scenario(vid::VariableID)::ScenarioID

Returns the `ScenarioID` of the specified `VariableID`.
"""
function scenario(vid::VariableID)::ScenarioID
    return vid.scenario
end

"""
    stage(vid::VariableID)::StageID

Returns the `StageID` of the specified `VariableID`.
"""
function stage(vid::VariableID)::StageID
    return vid.stage
end

"""
    index(vid::VariableID)::Index

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
    scid(n::$(SCENARIO_ID))::ScenarioID

Create `ScenarioID` from `n`.
"""
function scid(n::SCENARIO_ID)::ScenarioID
    return ScenarioID(SCENARIO_ID(n))
end

"""
    stid(n::$(STAGE_ID))::StageID

Create `StageID` from `n`.
"""
function stid(n::STAGE_ID)::StageID
    return StageID(STAGE_ID(n))
end

"""
    index(n::$(INDEX))::Index

Create `Index` from `n`.
"""
function index(n::INDEX)::Index
    return Index(INDEX(n))
end

"""
Unique identifier for consensus variables. The scenario variables being driven to consensus with this variable is given by `convert_to_variable_ids`.
"""
struct XhatID
    node::NodeID
    index::Index
end

function Base.isless(a::XhatID, b::XhatID)
    return (a.node < b.node ||
            (a.node == b.node && a.index < b.index))
end
