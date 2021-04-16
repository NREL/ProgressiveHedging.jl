
mutable struct Generator
    next_node_id::NODE_ID
    next_scenario_id::SCENARIO_ID
end

function Generator()::Generator
    return Generator(0,0)
end

function _generate_node_id(gen::Generator)::NodeID
    id = NodeID(gen.next_node_id)
    gen.next_node_id += 1
    return id
end

function _generate_scenario_id(gen::Generator)::ScenarioID
    id = ScenarioID(gen.next_scenario_id)
    gen.next_scenario_id += 1
    return id
end

"""
Struct representing a node in a scenario tree.
"""
struct ScenarioNode
    id::NodeID # id of this node
    stage::StageID # stage of this node
    scenario_bundle::Set{ScenarioID} # scenarios that are indistiguishable
    parent::Union{Nothing,ScenarioNode}
    children::Set{ScenarioNode}
end

Base.show(io::IO, sn::ScenarioNode) = print(io, "ScenarioNode($(sn.id), $(sn.stage), $(sn.scenario_bundle))")

function _add_child(parent::ScenarioNode,
                    child::ScenarioNode,
                    )::Nothing
    push!(parent.children, child)
    return
end

function _create_node(gen::Generator,
                      parent::Union{Nothing,ScenarioNode}
                      )::ScenarioNode
    nid = _generate_node_id(gen)
    stage = (parent==nothing ? StageID(1) : _increment(parent.stage))
    sn = ScenarioNode(nid, stage,
                      Set{ScenarioID}(),
                      parent,
                      Set{ScenarioNode}())
    if parent != nothing
        _add_child(parent, sn)
    end
    return sn
end

function id(node::ScenarioNode)::NodeID
    return node.id
end

function stage(node::ScenarioNode)::StageID
    return node.stage
end

"""
Struct representing the scenario structure of a stochastic program.

Can be built up by the user using the functions `add_node` and `add_leaf`.

**Constructor**

ScenarioTree()

Default constructor generates the root node of the tree. Can get the root node with `root`.
"""
struct ScenarioTree
    root::ScenarioNode
    tree_map::Dict{NodeID, ScenarioNode} # map from NodeID to tree node
    prob_map::Dict{ScenarioID, Float64}
    id_gen::Generator
end

function ScenarioTree(root_node::ScenarioNode,
                      gen::Generator,
                      )::ScenarioTree

    tree_map = Dict{NodeID, ScenarioNode}()
    prob_map = Dict{ScenarioID, Float64}()

    st = ScenarioTree(root_node,
                      tree_map,
                      prob_map,
                      gen)

    _add_node(st, root_node)
    return st
end

function ScenarioTree()::ScenarioTree
    gen = Generator()
    rn = _create_node(gen, nothing)
    st = ScenarioTree(rn, gen)
    return st
end

"""
    root(tree::ScenarioTree)

Return the root node of the given ScenarioTree
"""
function root(tree::ScenarioTree)::ScenarioNode
    return tree.root
end

function last_stage(tree::ScenarioTree)::StageID
    return maximum(getfield.(values(tree.tree_map), :stage))
end

function is_leaf(tree::ScenarioTree, vid::VariableID)::Bool
    return is_leaf(node(tree, vid.scenario, vid.stage))
end

function is_leaf(node::ScenarioNode)::Bool
    return length(node.children) == 0 ||
        (length(node.children) == 1 && is_leaf(first(node.children)))
end

function is_leaf(tree::ScenarioTree, nid::NodeID)::Bool
    return is_leaf(tree.tree_map[nid])
end

function is_leaf(tree::ScenarioTree, node::ScenarioNode)::Bool
    return is_leaf(tree.tree_map[node.id])
end

function _add_node(tree::ScenarioTree, node::ScenarioNode)::Nothing
    tree.tree_map[node.id] = node
    return
end

"""
    add_node(tree::ScenarioTree, parent::ScenarioNode)

Add a node to the ScenarioTree `tree` with parent node `parent`. Return the added node. If the node to add is a leaf, use `add_leaf` instead.
"""
function add_node(tree::ScenarioTree,
                  parent::ScenarioNode,
                  )::ScenarioNode
    new_node = _create_node(tree.id_gen, parent)
    _add_node(tree, new_node)
    return new_node
end

function _add_scenario_to_bundle(tree::ScenarioTree,
                                 nid::NodeID,
                                 scid::ScenarioID,
                                 )::Nothing
    push!(tree.tree_map[nid].scenario_bundle, scid)
    return
end

"""
    add_leaf(tree::ScenarioTree, parent::ScenarioNode, probability<:Real)

Add a leaf to the ScenarioTree `tree` with parent node `parent`. The probability of this scenario occuring is given by `probability`. Returns the ScenarioID representing the scenario.
"""
function add_leaf(tree::ScenarioTree,
                  parent::ScenarioNode,
                  probability::R,
                  )::ScenarioID where R <: Real

    if probability < 0.0 || probability > 1.0
        error("Invalid probability value: $probability")
    end

    leaf = add_node(tree, parent)
    scid = _assign_scenario_id(tree)
    tree.prob_map[scid] = probability

    node = leaf
    while node != nothing
        id = node.id
        _add_scenario_to_bundle(tree, id, scid)
        node = node.parent
    end

    return scid
end

_assign_scenario_id(tree::ScenarioTree)::ScenarioID = _generate_scenario_id(tree.id_gen)

function node(tree::ScenarioTree,
              nid::NodeID
              )::ScenarioNode
    return tree.tree_map[nid]
end

function node(tree::ScenarioTree,
              scid::ScenarioID,
              stid::StageID
              )::Union{Nothing,ScenarioNode}

    ret_node = nothing

    for node in values(tree.tree_map)

        if stage(node) == stid && scid in scenario_bundle(node)
            ret_node = node
            break
        end

    end

    return ret_node

end

function scenario_bundle(node::ScenarioNode)::Set{ScenarioID}
    return node.scenario_bundle
end

function scenario_bundle(tree::ScenarioTree, nid::NodeID)::Set{ScenarioID}
    return scenario_bundle(tree.tree_map[nid])
end

scenarios(tree::ScenarioTree)::Set{ScenarioID} = tree.root.scenario_bundle

function scenario_nodes(tree::ScenarioTree)
    return collect(values(tree_map))
end

function scenario_nodes(tree::ScenarioTree, scid::ScenarioID)
    nodes = Vector{ScenarioNode}()
    for node in values(tree.tree_map)
        if scid in scenario_bundle(node)
            push!(nodes, node)
        end
    end
    return nodes
end
