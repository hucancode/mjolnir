package tests

import "core:testing"

@(test)
delete_unallocated_slice :: proc(t: ^testing.T) {
    arr :[]u32
    delete(arr)
}
