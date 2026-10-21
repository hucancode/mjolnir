#+build !js
#+private
package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_chain_samples_the_path_travelled :: proc(t: ^testing.T) {
  chain: Chain([2]f32)
  chain_init(&chain, {0, 0}, {0, 1}, 4, 0.5)
  defer chain_destroy(&chain)
  chain_move(&chain, {2, 0})
  chain_move(&chain, {2, 1})
  testing.expect_value(t, chain_sample(chain, 0), [2]f32{2, 1})
  testing.expect_value(t, chain_sample(chain, 0.5), [2]f32{2, 0.5})
  testing.expect_value(t, chain_sample(chain, 1), [2]f32{2, 0})
  testing.expect_value(t, chain_sample(chain, 2), [2]f32{1, 0})
  testing.expect_value(t, chain_sample(chain, 3), [2]f32{0, 0})
}

@(test)
test_chain_starts_straight_behind_the_head :: proc(t: ^testing.T) {
  chain: Chain([3]f32)
  chain_init(&chain, {1, 0, 1}, {0, 0, 1}, 2, 0.5)
  defer chain_destroy(&chain)
  testing.expect_value(t, chain_sample(chain, 1), [3]f32{1, 0, 2})
  testing.expect_value(t, chain_sample(chain, 100), chain.points[len(chain.points) - 1])
}

@(test)
test_chain_follow_keeps_head_and_link_lengths :: proc(t: ^testing.T) {
  chain: Chain([2]f32)
  chain_init(&chain, {0, 0}, {-1, 0}, 3, 0.5)
  defer chain_destroy(&chain)
  for i in 0 ..< 200 do chain_follow(&chain, {f32(i) * 0.01, 2 * math.sin(f32(i) * 0.05)}, 0.6, math.PI)
  testing.expect_value(t, chain.head, [2]f32{1.99, 2 * math.sin(f32(199) * 0.05)})
  leader := chain.head
  for p in chain.points {
    testing.expect(t, linalg.distance(leader, p) < 0.5 + 0.05)
    leader = p
  }
}

@(test)
test_chain_follow_limits_bend :: proc(t: ^testing.T) {
  chain: Chain([2]f32)
  chain_init(&chain, {0, 0}, {-1, 0}, 3, 0.5)
  defer chain_destroy(&chain)
  limit := math.to_radians(f32(30))
  for _ in 0 ..< 300 do chain_follow(&chain, {0, 0.001}, 1, limit)
  chain_follow(&chain, {0, 1}, 1, limit)
  for i in 1 ..< len(chain.points) - 1 {
    before := linalg.normalize(chain.points[i] - chain.points[i - 1])
    after := linalg.normalize(chain.points[i + 1] - chain.points[i])
    testing.expect(t, math.acos(clamp(linalg.dot(before, after), -1, 1)) < limit + 0.05)
  }
}

@(test)
test_chain_swing_hangs_from_head_and_keeps_link_length :: proc(t: ^testing.T) {
  chain: Chain([2]f32)
  chain_init(&chain, {0, 0}, {1, 0}, 2, 0.5)
  defer chain_destroy(&chain)
  chain_hang(&chain, {0, 0}, {1, 0})
  for i in 0 ..< 60 do chain_swing(&chain, {0, f32(i) * 0.02}, {1, 0}, 0.9, 0.1, 0.8)
  testing.expect_value(t, chain.head, [2]f32{0, 1.18})
  leader := chain.head
  for p in chain.points {
    testing.expect(t, abs(linalg.distance(leader, p) - chain.step) < 0.05)
    leader = p
  }
}

@(test)
test_chain_swing_straightens_when_head_jumps :: proc(t: ^testing.T) {
  chain: Chain([2]f32)
  chain_init(&chain, {0, 0}, {1, 0}, 2, 0.5)
  defer chain_destroy(&chain)
  chain_hang(&chain, {0, 0}, {1, 0})
  chain_swing(&chain, {0, 5}, {0, 1}, 0.9, 0.1, 0.8)
  testing.expect_value(t, chain.head, [2]f32{0, 5})
  testing.expect_value(t, chain.points[0], [2]f32{0, 5.5})
}

@(test)
test_chain_swing_stays_bounded_under_fast_head :: proc(t: ^testing.T) {
  chain: Chain([2]f32)
  chain_init(&chain, {0, 0}, {1, 0}, 2, 0.5)
  defer chain_destroy(&chain)
  chain_hang(&chain, {0, 0}, {1, 0})
  for i in 0 ..< 400 {
    side := f32(1 if (i / 7) % 2 == 0 else -1)
    chain_swing(&chain, chain.head + {0, side * 0.7}, {0, -1}, 0.88, 0.1, 0.8)
    for p in chain.points do testing.expect(t, linalg.distance(p, chain.head) < chain.step * f32(len(chain.points)) + 0.001)
  }
}
