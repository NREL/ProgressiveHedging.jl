# Functions

```@index
Pages = ["functions.md"]
```

## Callback Creation and Retrieval

```@docs
apply_to_subproblem
cb
get_callback
get_callback_ext
mean_deviation
spcb
variable_fixing
```

## ID Type Interactions

```@docs
convert_to_variable_ids
convert_to_xhat_id
index
scenario
scid
stage
stage_id
stid
value(::Index)
value(::NodeID)
value(::ScenarioID)
value(::StageID)
```

## Result Retrieval

```@docs
lower_bounds
print_timing
residuals
retrieve_soln
retrieve_aug_obj_value
retrieve_obj_value
retrieve_no_hats
retrieve_no_hat_history
retrieve_w
retrieve_w_history
retrieve_xhat_history
```

## Problem Accessors

```@docs
probability
scenario_tree
scenarios
```

## Scenario Tree

```@docs
add_node
add_leaf
root
two_stage_tree
```

## Variable Interactions

```@docs
branch_value
consensus_variables
is_integer
is_leaf
leaf_value
name
scenario_bundle
value(::HatVariable)
value(::PHData, ::VariableID)
value(::PHData, ::ScenarioID, ::StageID, ::Index)
variables
w_value
xhat_value
```
