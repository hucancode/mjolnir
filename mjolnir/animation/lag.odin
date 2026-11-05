package animation

import "core:slice"

// Lead and follow-through are one mechanism: each link of a chain reads the same signal at its own
// time, averaged over a short window so it settles after a jerk instead of copying it. Positive
// offsets follow (drag, overlapping action: a tail, a cable, a foot's toes after its heel);
// negative ones lead (anticipation: a hip turning before the shoulders).
//
// A signal is any floats (bone rotations, channel values), read one of two ways:
//   - lag_sample re-samples a source that can be evaluated at any time (a clip, a procedural
//     motion): deterministic and scrubbable, and the only way to lead.
//   - LagHistory records a signal as it happens (gameplay, physics) and lag_read reads it back:
//     follows only, there is no future to lead from.

// Lag is when link k of a chain reads its signal: averaged over `samples` reads (at least 1),
// read j (1 to samples) at
//   t - delay - k * step - window * j / samples
// so `window` 0 is one read at t - delay - k * step.
Lag :: struct {
  delay, step, window: f32,
  samples:             int,
}

// lag_offset is how long before t read `j` (1 to samples) of link `link` is (Lag).
lag_offset :: proc(lag: Lag, link, j: int) -> f32 {
  return lag.delay + f32(link) * lag.step + lag.window * f32(j) / f32(max(lag.samples, 1))
}

// LagSource is a signal to re-sample: `sample` writes it at time t into `out`.
LagSource :: struct {
  data:   rawptr,
  sample: proc(data: rawptr, t: f32, out: []f32),
}

// lag_sample writes into `out` what link `link` reads of `src` at time `t` (Lag): the average of
// its reads.
lag_sample :: proc(lag: Lag, link: int, t: f32, src: LagSource, out: []f32) {
  n := max(lag.samples, 1)
  read := make([]f32, len(out), context.temp_allocator)
  slice.zero(out)
  for j in 1 ..= n {
    src.sample(src.data, t - lag_offset(lag, link, j), read)
    for v, i in read do out[i] += v
  }
  for &v in out do v /= f32(n)
}

// LagHistory is a signal as recorded: up to len(times) frames, newest at `head`, each
// len(values) / len(times) floats. A view: fill one over memory of your own (zeroed), or
// lag_history_make.
LagHistory :: struct {
  times:       []f32,
  values:      []f32,
  head, count: int,
}

// lag_history_make is a LagHistory of `frames` frames of `width` floats; free with
// lag_history_destroy.
lag_history_make :: proc(frames, width: int, allocator := context.allocator) -> LagHistory {
  return {times = make([]f32, frames, allocator), values = make([]f32, frames * width, allocator)}
}

lag_history_destroy :: proc(h: ^LagHistory, allocator := context.allocator) {
  delete(h.times, allocator)
  delete(h.values, allocator)
  h^ = {}
}

// lag_frame is frame `k` of `h` (0 the newest): its time and values.
@(private = "file")
lag_frame :: proc(h: ^LagHistory, k: int) -> (t: f32, values: []f32) {
  frames := len(h.times)
  i := (h.head - k + frames) % frames
  width := len(h.values) / frames
  return h.times[i], h.values[i * width:][:width]
}

// lag_record records `values` at time `t` (later than the last), the oldest frame making room.
lag_record :: proc(h: ^LagHistory, t: f32, values: []f32) {
  frames := len(h.times)
  if frames == 0 do return
  h.head = (h.head + 1) % frames
  h.count = min(h.count + 1, frames)
  width := len(h.values) / frames
  h.times[h.head] = t
  copy(h.values[h.head * width:][:width], values)
}

// lag_at writes the signal of `h` at time `t` into `out`: between the two frames around it, the
// newest after it, or the oldest before it. Nothing recorded leaves `out` as it is.
lag_at :: proc(h: ^LagHistory, t: f32, out: []f32) {
  if h.count == 0 do return
  newer_t, newer := lag_frame(h, 0)
  if t >= newer_t {
    copy(out, newer)
    return
  }
  for k in 1 ..< h.count {
    older_t, older := lag_frame(h, k)
    if t >= older_t {
      span := newer_t - older_t
      u := (t - older_t) / span if span > 0 else 1
      for &v, i in out do v = older[i] + (newer[i] - older[i]) * u
      return
    }
    newer_t, newer = older_t, older
  }
  copy(out, newer)
}

// lag_read writes into `out` what link `link` reads of `h` at time `t` (Lag): the average of its
// reads. Reads before the oldest frame take the oldest; reads ahead of the newest, the newest.
lag_read :: proc(h: ^LagHistory, lag: Lag, link: int, t: f32, out: []f32) {
  n := max(lag.samples, 1)
  read := make([]f32, len(out), context.temp_allocator)
  slice.zero(out)
  for j in 1 ..= n {
    lag_at(h, t - lag_offset(lag, link, j), read)
    for v, i in read do out[i] += v
  }
  for &v in out do v /= f32(n)
}
