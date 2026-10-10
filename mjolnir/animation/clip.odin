package animation

import "core:math/linalg"
import "core:strings"

// Location of one track's keys inside a Clip's flat arrays. count = 0 means
// the component is not animated.
TrackRange :: struct {
  time_offset:   u32,
  value_offset:  u32,
  count:         u32,
  interpolation: Interpolation,
}

// Animated components of one target (a bone, or any caller-defined slot).
Channel :: struct {
  position, rotation, scale: TrackRange,
}

// A set of channels sharing one timeline. All keys live in flat arrays; each
// channel refers to its slice by range.
Clip :: struct {
  name:      string,
  duration:  f32,
  channels:  []Channel,
  times:     [dynamic]f32,
  positions: [dynamic][3]f32,
  rotations: [dynamic]quaternion128,
  scales:    [dynamic][3]f32,
}

// Initialise an empty clip; any previous contents of `self` are discarded, not freed.
clip_init :: proc(self: ^Clip, channel_count: int, name: string = "", duration: f32 = 0) {
  self^ = {}
  self.name = strings.clone(name)
  self.duration = duration
  self.channels = make([]Channel, channel_count)
}

clip_destroy :: proc(self: ^Clip) {
  delete(self.name)
  delete(self.channels)
  delete(self.times)
  delete(self.positions)
  delete(self.rotations)
  delete(self.scales)
  self^ = {}
}

@(private)
clip_append :: proc(
  self: ^Clip,
  values: ^[dynamic]$T,
  times: []f32,
  src: []T,
  interpolation: Interpolation,
) -> TrackRange {
  r := TrackRange {
    time_offset   = u32(len(self.times)),
    value_offset  = u32(len(values)),
    count         = u32(len(times)),
    interpolation = interpolation,
  }
  append(&self.times, ..times)
  append(values, ..src)
  if len(times) > 0 do self.duration = max(self.duration, times[len(times) - 1])
  return r
}

// Copy keys into the clip. For CUBIC, `values` holds 3 entries per key
// (in-tangent, value, out-tangent).
clip_set_positions :: proc(self: ^Clip, channel: int, times: []f32, values: [][3]f32, interpolation: Interpolation = .LINEAR) {
  self.channels[channel].position = clip_append(self, &self.positions, times, values, interpolation)
}

clip_set_rotations :: proc(self: ^Clip, channel: int, times: []f32, values: []quaternion128, interpolation: Interpolation = .LINEAR) {
  self.channels[channel].rotation = clip_append(self, &self.rotations, times, values, interpolation)
}

clip_set_scales :: proc(self: ^Clip, channel: int, times: []f32, values: [][3]f32, interpolation: Interpolation = .LINEAR) {
  self.channels[channel].scale = clip_append(self, &self.scales, times, values, interpolation)
}

@(private)
track_view :: #force_inline proc(r: TrackRange, times: []f32, values: []$T) -> Track(T) {
  n := int(r.count)
  vn := n * 3 if r.interpolation == .CUBIC else n
  return {
    times         = times[r.time_offset:][:n],
    values        = values[r.value_offset:][:vn],
    interpolation = r.interpolation,
  }
}

clip_position_track :: proc(self: ^Clip, channel: int) -> Track([3]f32) {
  return track_view(self.channels[channel].position, self.times[:], self.positions[:])
}

clip_rotation_track :: proc(self: ^Clip, channel: int) -> Track(quaternion128) {
  return track_view(self.channels[channel].rotation, self.times[:], self.rotations[:])
}

clip_scale_track :: proc(self: ^Clip, channel: int) -> Track([3]f32) {
  return track_view(self.channels[channel].scale, self.times[:], self.scales[:])
}

// Sample one channel; a component is nil when the channel does not animate it.
clip_sample_channel :: proc(
  self: ^Clip,
  channel: int,
  t: f32,
) -> (
  position: Maybe([3]f32),
  rotation: Maybe(quaternion128),
  scale: Maybe([3]f32),
) {
  if channel < 0 || channel >= len(self.channels) do return
  ch := self.channels[channel]
  if ch.position.count > 0 do position = track_sample(clip_position_track(self, channel), t, [3]f32{})
  if ch.rotation.count > 0 do rotation = track_sample(clip_rotation_track(self, channel), t, linalg.QUATERNIONF32_IDENTITY)
  if ch.scale.count > 0 do scale = track_sample(clip_scale_track(self, channel), t, [3]f32{1, 1, 1})
  return
}

// Sample a channel into `out`, keeping components the channel does not animate.
clip_sample_trs :: proc(self: ^Clip, channel: int, t: f32, out: ^TRS) {
  p, r, s := clip_sample_channel(self, channel, t)
  if v, ok := p.?; ok do out.position = v
  if v, ok := r.?; ok do out.rotation = v
  if v, ok := s.?; ok do out.scale = v
}
