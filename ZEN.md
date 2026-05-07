# Rules for a coder
- single source of truth. no derived info unless perf evidence
- no dup info across structs. no pointer on struct
- min struct count
- modules layered, deps top→bottom, <5 layers
- no indirection/wrapper
- user write less code. no leak internal detail