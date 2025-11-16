package algebra

import "core:math"

// Next power of two
next_pow2 :: proc "contextless" (v: u32) -> u32 {
  val := v
  val -= 1
  val |= val >> 1
  val |= val >> 2
  val |= val >> 4
  val |= val >> 8
  val |= val >> 16
  val += 1
  return val
}

// Integer log base 2
ilog2 :: proc "contextless" (v: u32) -> u32 {
  val := v
  r: u32 = 0
  shift: u32
  shift = u32(val > 0xffff) << 4
  val >>= shift
  r |= shift
  shift = u32(val > 0xff) << 3
  val >>= shift
  r |= shift
  shift = u32(val > 0xf) << 2
  val >>= shift
  r |= shift
  shift = u32(val > 0x3) << 1
  val >>= shift
  r |= shift
  r |= val >> 1
  return r
}

log2_greater_than :: proc "contextless" (x: u32) -> u32 {
  return u32(math.floor(math.log2(f32(x)))) + 1
}

// Align value to given alignment
align :: proc "contextless" (value, alignment: int) -> int {
  return (value + alignment - 1) & ~(alignment - 1)
}
