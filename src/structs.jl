
# struct ModelInfo{K}
#     id::String
#     stage::Int
#     scen_bundle::Set{K}
# end

# struct PHInitInfo{K}
#     scenarios::Set{K}
#     leaves::Dict{K,StructJuMP.StructuredModel}
#     node_map::Dict{StructJuMP.StructuredModel, ModelInfo{K}}
# end

const NODE_ID = Int
const SCENARIO_ID = Int
const STAGE_ID = Int
const INDEX = Int

struct NodeID
    value::NODE_ID
end
_value(nid::NodeID)::NODE_ID = nid.value
Base.isless(a::NodeID, b::NodeID) = _value(a) < _value(b)

struct ScenarioID
    value::SCENARIO_ID
end
_value(scid::ScenarioID)::SCENARIO_ID = scid.value
Base.isless(a::ScenarioID, b::ScenarioID) = _value(a) < _value(b)

const DUMMY_SCENARIO_ID = ScenarioID(-1)

struct StageID
    value::STAGE_ID
end
_value(sid::StageID)::STAGE_ID = sid.value
Base.isless(a::StageID, b::StageID) = _value(a) < _value(b)

const DUMMY_STAGE_ID = StageID(-1)

struct Index
    value::INDEX
end
_value(idx::Index)::INDEX = idx.value
_increment(index::Index)::Index = Index(_value(index) + one(INDEX))
Base.isless(a::Index, b::Index) = _value(a) < _value(b)

mutable struct Generator
    next_node_id::NODE_ID
    # next_stage_id::STAGE_ID
    next_scenario_id::SCENARIO_ID
end

function Generator()
    return Generator(0,0)
end

function _generate_node_id(gen::Generator)::NodeID
    id = NodeID(gen.next_node_id)
    gen.next_node_id += 1
    return id
end

# function _generate_stage_id(gen::Generator)
#     id = StageID(gen.next_stage_id)
#     gen.next_stage_id += 1
#     return id
# end

function _generate_scenario_id(gen::Generator)::ScenarioID
    id = ScenarioID(gen.next_scenario_id)
    gen.next_scenario_id += 1
    return id
end

struct VariableID
    scenario::ScenarioID # scenario to which this variable belongs
    stage::StageID # stage to which this variable belongs
    index::Index # coordinate in vector
end
function Base.isless(a::VariableID, b::VariableID)
    return (a.stage < b.stage ||
            (a.stage == b.stage &&
             (a.scenario < b.scenario) ||
             (a.scenario == b.scenario && a.index < b.index)))
end

struct XhatID
    node::NodeID
    index::Index
end
function Base.isless(a::XhatID, b::XhatID)
    return (a.node < b.node ||
            (a.node == b.node && a.index < b.index))
end

struct VariableInfo
    ref::Future
end

struct Translator{A,B}
    a_to_b::Dict{A,B}
    b_to_a::Dict{B,A}
end

function Translator{A,B}() where {A,B}
    return Translator(Dict{A,B}(), Dict{B,A}())
end

function add_pair(t::Translator{A,B}, a::A, b::B) where{A,B}
    if !(a in keys(t.a_to_b)) && !(b in keys(t.b_to_a))
        t.a_to_b[a] = b
        t.b_to_a[b] = a
    else
        @error("One of $a or $b already maps to something")
    end
    return
end

function translate(t::Translator{A,B}, a::A) where {A,B}
    return t.a_to_b[a]
end

function translate(t::Translator{A,B}, b::B) where {A,B}
    return t.b_to_a[b]
end

struct ScenarioNode
    id::NodeID # id of this node
    stage::StageID # stage of this node
    scenario_bundle::Set{ScenarioID} # scenarios that are indistiguishable
    variable_indices::Set{Index} # var indices
    num_variables::Int
    # parent::Union{Nothing, ScenarioNode}
    # children::Dict{NodeID, ScenarioNode}
end

function _create_node(gen::Generator, stage::StageID,
                      sjm::StructJuMP.StructuredModel)
    nid = _generate_node_id(gen)
    nvar = length(keys(sjm.variables))
    sn = ScenarioNode(nid, stage, Set{ScenarioID}(), Set{Index}(), nvar)
    return sn
end

function next_index(node::ScenarioNode)
    v_set = node.variable_indices
    idx = isempty(v_set) ? Index(1) : (_increment(maximum(v_set)))
    push!(node.variable_indices, idx)
    return idx
end

const SJPHTranslator = Translator{StructJuMP.StructuredModel, ScenarioNode}
# const VarRefTranslator = Translator{StructJuMP.StructuredVariableRef,
#                                     V} where {V <: JuMP.AbstractVariableRef}

struct ScenarioTree
    root::ScenarioNode
    tree_map::Dict{NodeID, ScenarioNode} # map from NodeID to tree node
    stage_map::Dict{StageID, Set{NodeID}} # nodes in each stage
    id_gen::Generator
    sj_ph_translator::SJPHTranslator
end

function ScenarioTree(root_node::ScenarioNode, gen::Generator,
                      trans::SJPHTranslator)
    tree_map = Dict{NodeID, ScenarioNode}()
    stage_map = Dict{StageID, Set{NodeID}}()
    st = ScenarioTree(root_node, tree_map, stage_map, gen,
                      trans)
    _add_node(st, root_node)
    return st
end

function ScenarioTree(root_model::StructJuMP.StructuredModel)
    gen = Generator()
    sn = _create_node(gen, StageID(1), root_model)
    trans = SJPHTranslator()
    add_pair(trans, root_model, sn)
    return ScenarioTree(sn, gen, trans)
end

function _add_node(tree::ScenarioTree, node::ScenarioNode)
    tree.tree_map[node.id] = node
    if node.stage in keys(tree.stage_map)
        push!(tree.stage_map[node.stage], node.id)
    else
        tree.stage_map[node.stage] = Set{NodeID}([node.id])
    end
    return
end

function add_node(tree::ScenarioTree, model::StructJuMP.StructuredModel,
                  stage::StageID)
    new_node = _create_node(tree.id_gen, stage, model)
    add_pair(tree.sj_ph_translator, model, new_node)
    _add_node(tree, new_node)
    return new_node
end

function add_scenario(tree::ScenarioTree, nid::NodeID, scid::ScenarioID)
    push!(tree.tree_map[nid].scenario_bundle, scid)
    return
end

function add_scenario(tree::ScenarioTree,
                      leaf_model::StructJuMP.StructuredModel)
    scid = assign_scenario_id(tree)
    model = leaf_model
    while model != nothing
        nid = translate(tree, model).id
        add_scenario(tree, nid, scid)
        model = StructJuMP.getparent(model)
    end
    return scid
end

assign_scenario_id(tree::ScenarioTree)::ScenarioID = _generate_scenario_id(tree.id_gen)

scenarios(tree::ScenarioTree) = tree.root.scenario_bundle

function translate(tree::ScenarioTree, sjm::StructJuMP.StructuredModel)
    return translate(tree.sj_ph_translator, sjm)
end

function translate(tree::ScenarioTree, node::ScenarioNode)
    return translate(tree.sj_ph_translator, node)
end

function translate(tree::ScenarioTree, nid::NodeID)
    node = tree.tree_map[nid]
    return translate(tree, node)
end

struct PHData
    r::Float64
    scenario_tree::ScenarioTree
    scen_proc_map::Dict{ScenarioID, Int}
    probabilities::Dict{ScenarioID, Float64}
    submodels::Dict{ScenarioID, Future}
    variable_map::Dict{VariableID, VariableInfo}
    name::Dict{VariableID, String}
    W::Dict{VariableID, Float64}
    W_ref::Dict{VariableID, Future}
    Xhat::Dict{XhatID, Float64}
    Xhat_ref::Dict{XhatID, Dict{ScenarioID, Future}}
end

function PHData(r::N, tree::ScenarioTree,
                scen_proc_map::Dict{ScenarioID, Int},
                probs::Dict{ScenarioID, Float64},
                submodels::Dict{ScenarioID, Future},
                var_map::Dict{VariableID, VariableInfo},
                name_map::Dict{VariableID, String}
                ) where {N <: Number}

    w_dict = Dict{VariableID, Float64}(vid => 0.0 for vid in keys(var_map))
    xhat_dict = Dict{XhatID, Float64}()

    for (nid, ninfo) in pairs(tree.tree_map)
        for i in ninfo.variable_indices
            xhat_id = XhatID(nid, i)
            xhat_dict[xhat_id] = 0.0
        end
    end

    return PHData(float(r),
                  tree,
                  scen_proc_map,
                  probs,
                  submodels,
                  var_map,
                  name_map,
                  w_dict,
                  Dict{VariableID, Future}(),
                  xhat_dict,
                  Dict{XhatID, Dict{ScenarioID, Future}}())
end

function stage_id(xid::XhatID, phd::PHData)::StageID
    return phd.scenario_tree.tree_map[xid.node].stage
end

function scenario_bundle(xid::XhatID, phd::PHData)::Set{ScenarioID}
    return phd.scenario_tree.tree_map[xid.node].scenario_bundle
end

function convert_to_variable_set(xid::XhatID, phd::PHData)::Set{VariableID}
    idx = xid.index
    stage = stage_id(xid, phd)
    scens = scenario_bundle(xid, phd)
    
    vset = Set{VariableID}()
    for s in scens
        push!(vset, VariableID(s, stage, idx))
    end
    
    return vset
end

function convert_to_variable_id(xid::XhatID, phd::PHData)::VariableID
    idx = xid.index
    stage = stage_id(xid, phd)
    scen = first(scenario_bundle(xid, phd))
    return VariableID(scen, stage, idx)
end

function convert_to_xhat_id(vid::VariableID, phd::PHData)::XhatID
    nodes = phd.scenario_tree.stage_map[vid.stage]
    node_id = -1
    for nid in nodes
        if vid.scenario in phd.scenario_tree.tree_map[nid].scenario_bundle
            node_id = nid
            break
        end
    end
    return XhatID(node_id, vid.index)
end
