1. single source of truth. no derived/duplicated info across structs. no pointer on struct
2. few structs
3. modules layered, modules in layer n import layer n-1 or less, at most 5 layers
4. generic, straightforward, no special-casing
5. terse, avoid thin wrapper
6. data-oriented, use large contiguous array
