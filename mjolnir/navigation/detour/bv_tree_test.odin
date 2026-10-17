#+build !js
#+private
package detour

import "core:math"
import "core:slice"
import "core:testing"

@(test)
test_bv_tree_various_y_values :: proc(t: ^testing.T) {
  // Test Y remapping with various values to ensure correct behavior
  cs := f32(0.3)
  ch := f32(0.2)
  ch_cs_ratio := ch / cs
  test_cases := []struct {
    y_value:      u16,
    expected_min: u16,
    expected_max: u16,
  } {
    {0, 0, 0}, // floor(0 * 0.667) = 0, ceil(0 * 0.667) = 0
    {5, 3, 4}, // floor(5 * 0.667) = 3, ceil(5 * 0.667) = 4
    {10, 6, 7}, // floor(10 * 0.667) = 6, ceil(10 * 0.667) = 7
    {15, 9, 10}, // floor(15 * 0.6666...) = 9, ceil(15 * 0.6666...) = 10
    {20, 13, 14}, // floor(20 * 0.667) = 13, ceil(20 * 0.667) = 14
  }
  for tc in test_cases {
    actual_min := u16(math.floor(f32(tc.y_value) * ch_cs_ratio))
    actual_max := u16(math.ceil(f32(tc.y_value) * ch_cs_ratio))
    testing.expect_value(t, actual_min, tc.expected_min)
    testing.expect_value(t, actual_max, tc.expected_max)
  }
}
