package tests
import "core:testing"

@(test)
test_bitset_int_conversion :: proc(t: ^testing.T) {
  Features :: enum {
    SKINNING,
    SHADOWS,
    REFLECTIONS,
  }
  FeatureSet :: bit_set[Features]
  testing.expect(t, u32(FeatureSet {}) == 0)
  testing.expect(t, u32(FeatureSet {.SHADOWS, .SKINNING}) == 0b11)
}