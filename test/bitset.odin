package tests
import "core:testing"

@(test)
test_bitset_int_conversion :: proc(t: ^testing.T) {
  Features :: enum {
    SKINNING,
    SHADOWS,
    REFLECTIONS,
  }
  FeatureSet :: bit_set[Features; u32]
  // bit_set to u32
  features := FeatureSet {.SHADOWS, .SKINNING}
  testing.expect_value(t, transmute(u32)features, 0b11)
  // u32 to bit_set
  mask : u32 = 0b11
  testing.expect_value(t, transmute(FeatureSet)mask, FeatureSet {.SHADOWS, .SKINNING})
  testing.expect_value(t, len(Features), 3)
}
