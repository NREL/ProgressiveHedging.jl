# Interfaces

```@index
Pages = ["interfaces.md"]
```

## Penalty Parameter

```@docs
AbstractPenaltyParameter
get_penalty_value
is_initial_value_dependent
is_subproblem_dependent
is_variable_dependent
penalty_map
process_penalty_initial_value
process_penalty_subproblem
```

## Subproblem

### Types

```@docs
AbstractSubproblem
VariableInfo
```

### Required Functions

```@docs
add_ph_objective_terms
objective_value
report_values
report_variable_info
solve_subproblem
update_ph_terms
```

### Optional Functions

```@docs
warm_start
```

### Extensive Form Functions

```@docs
ef_copy_model
ef_node_dict_constructor
```

### Penalty Parameter Functions

```@docs
report_penalty_info
```

### Lower Bound Functions

```@docs
add_lagrange_terms
update_lagrange_terms
```
