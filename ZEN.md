# Rules for a coder
- single source of truth, avoid storing derived information unless you have evidence of performance issue
- do not duplicate information across structs, do not store pointer on struct
- keep the struct definition count minimum
- modules must be organized in layers, dependency go from top to bottom
- avoid indirection/wrapper when possible
- do not leak internal detail to user
