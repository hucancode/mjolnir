package algebra

import "core:testing"

@(test)
test_next_pow2 :: proc(t: ^testing.T) {
  testing.expect_value(t, next_pow2(0), u32(0))
  testing.expect_value(t, next_pow2(1), u32(1))
  testing.expect_value(t, next_pow2(2), u32(2))
  testing.expect_value(t, next_pow2(3), u32(4))
  testing.expect_value(t, next_pow2(5), u32(8))
  testing.expect_value(t, next_pow2(16), u32(16))
  testing.expect_value(t, next_pow2(17), u32(32))
  testing.expect_value(t, next_pow2(1000), u32(1024))
}

@(test)
test_ilog2 :: proc(t: ^testing.T) {
  testing.expect_value(t, ilog2(1), u32(0))
  testing.expect_value(t, ilog2(2), u32(1))
  testing.expect_value(t, ilog2(4), u32(2))
  testing.expect_value(t, ilog2(8), u32(3))
  testing.expect_value(t, ilog2(16), u32(4))
  testing.expect_value(t, ilog2(31), u32(4))
  testing.expect_value(t, ilog2(32), u32(5))
  testing.expect_value(t, ilog2(1024), u32(10))
}

@(test)
test_align :: proc(t: ^testing.T) {
  testing.expect_value(t, align(0, 4), 0)
  testing.expect_value(t, align(1, 4), 4)
  testing.expect_value(t, align(3, 4), 4)
  testing.expect_value(t, align(4, 4), 4)
  testing.expect_value(t, align(5, 4), 8)
  testing.expect_value(t, align(15, 8), 16)
  testing.expect_value(t, align(16, 8), 16)
}
