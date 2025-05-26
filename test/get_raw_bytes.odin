package tests

import "core:testing"
import "core:slice"

@(test)
get_pixel_data :: proc(t: ^testing.T) {
  n := 100
  float_pixels := make([]f32, n)
  defer delete(float_pixels)
  ptr := cast([^]u8)raw_data(float_pixels)
  data := ptr[:n * size_of(f32)]
  testing.expect(
    t,
    len(data) == len(float_pixels) * size_of(f32),
  )
  data = slice.to_bytes(float_pixels)
  testing.expect(
    t,
    len(data) == len(float_pixels) * size_of(f32),
  )
}
