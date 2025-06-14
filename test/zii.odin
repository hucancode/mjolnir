package tests

import "core:mem"
import "core:testing"

@(test)
delete_unallocated_slice :: proc(t: ^testing.T) {
  arr: []u32
  delete(arr)
  arr = nil
  delete(arr)
}

@(test)
loop_through_unallocated_slice :: proc(t: ^testing.T) {
  arr: []u32
  for x in arr do testing.fail_now(t)
  arr = nil
  for x in arr do testing.fail_now(t)
}

@(test)
copy_to_unallocated_slice :: proc(t: ^testing.T) {
  src: []u32 = {1, 2, 3}
  dst: []u32
  mem.copy(raw_data(dst), raw_data(src), min(len(src), len(dst)))
  testing.expect_value(t, len(dst), 0)
}

@(test)
copy_from_unallocated_slice :: proc(t: ^testing.T) {
  src: []u32
  dst: []u32 = {1, 2, 3}
  mem.copy(raw_data(dst), raw_data(src), min(len(src), len(dst)))
  testing.expect_value(t, dst[0], 1)
  testing.expect_value(t, dst[1], 2)
  testing.expect_value(t, dst[2], 3)
}
