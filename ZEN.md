1. single source of truth. no derived/duplicated info across structs. no pointer on struct
2. keep struct count minimal
3. modules layered, dependency go top→bottom, <5 layers
6. be straightforward, no branch/special-casing
4. be terse, no indirection/wrapper
5. data-oriented, use large constiguous array. hate small scattered arrays.
