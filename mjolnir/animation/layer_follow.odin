package animation

import "core:math/linalg"

// FollowParams gives a chain follow-through: each of its layer's bones (link k in the order given,
// head first) turns as the layers below turned it `lag` ago (Lag: link k reads later than link k-1
// by its step), so antennae, cables, ears and tails drag after the motion and settle after it stops,
// with nothing authored. It keeps `frames` frames of the chain's turns (0 = FOLLOW_FRAMES); they must
// cover the longest read (lag_offset of the last link) at the frame rate it runs at.
FollowParams :: struct {
  lag:    Lag,
  frames: u32,
}

FOLLOW_FRAMES :: 64

// A follow layer's state: [clock, head, count, times (frames), turns (frames x 4 per bone)].
@(private)
FOLLOW_HEADER :: 3

@(private)
follow_frames :: proc(p: FollowParams) -> int {
  return int(p.frames) if p.frames > 0 else FOLLOW_FRAMES
}

@(private)
follow_state_size :: proc(p: FollowParams, bones: int) -> int {
  frames := follow_frames(p)
  return FOLLOW_HEADER + frames + frames * 4 * bones
}

// Record the bones' local turns as the layers below left them, then turn each as it was when its
// link reads (lag_read), each bone on its parent as posed.
@(private)
follow_apply :: proc(pose: Pose, bones: []u32, state: []f32, params: FollowParams, delta_time: f32, fresh: bool) {
  n := len(bones)
  if n == 0 do return
  frames := follow_frames(params)
  if fresh do state[0], state[1], state[2] = 0, 0, 0
  clock := state[0] + delta_time
  h := LagHistory {
    times  = state[FOLLOW_HEADER:][:frames],
    values = state[FOLLOW_HEADER + frames:][:frames * 4 * n],
    head   = int(state[1]),
    count  = int(state[2]),
  }
  width := 4 * n
  now := make([]f32, width, context.temp_allocator)
  last := h.values[h.head * width:][:width]
  for b, k in bones {
    q := pose.local[b].rotation
    // on the same side as the frame before, so reads between frames turn the short way
    if h.count > 0 && q.x * last[4 * k] + q.y * last[4 * k + 1] + q.z * last[4 * k + 2] + q.w * last[4 * k + 3] < 0 do q = -q
    now[4 * k], now[4 * k + 1], now[4 * k + 2], now[4 * k + 3] = q.x, q.y, q.z, q.w
  }
  lag_record(&h, clock, now)
  read := make([]f32, width, context.temp_allocator)
  for b, k in bones {
    lag_read(&h, params.lag, k, clock, read)
    q := quaternion(x = read[4 * k], y = read[4 * k + 1], z = read[4 * k + 2], w = read[4 * k + 3])
    if linalg.length2(transmute([4]f32)q) > 1e-12 do pose.local[b].rotation = linalg.normalize(q)
    compose_bone(pose, b)
  }
  state[0], state[1], state[2] = clock, f32(h.head), f32(h.count)
}
