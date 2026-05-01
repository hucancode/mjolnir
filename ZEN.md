# Rules for a coder
- single source of truth, avoid storing derived information unless you have evidence of performance issue
- do not duplicate information across structs, do not store pointer on struct
- keep the struct definition count minimum
- avoid indirection/wrapper when possible
- modules should be self-contained and independent
- do not leak internal detail to user
