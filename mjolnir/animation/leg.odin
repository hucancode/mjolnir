package animation

import "core:math"
import "core:math/linalg"

// A leg is any limb that reaches for a point with the way it bends read off its rest pose: a human
// leg (knee forward), a dog's hind leg (hock back), a spider's (knee up), an arm (elbow back). The
// rig says how it bends, so no pole is placed by hand: leg_measure reads it once, leg_pole swings it
// with the limb, leg_reach solves. Walking, stepping and ground contact are built on it.

// LegRig is what leg_measure reads off a chain at rest. `middle` is the joint that bends it
// (ik_chain_middle; 0 none) and `ends` how many bones at its end are the end's own joints (an
// ankle, a wrist: they turn it, they don't reach); `end` is the point that reaches, in the last
// bone's frame (a sole, a palm). `bend` is the way the middle joint stands off the line from the
// joint above it to the end (`line`) at rest: bent at rest, the way it is bent (a strider's
// zigzag); straight, the side its stops let it bend. `length` is the chain's, root to end.
LegRig :: struct {
  middle, ends: u32,
  end:          [3]f32,
  bend, line:   [3]f32,
  length:       f32,
}

// leg_measure reads `chain` (root first, each bone the parent of the next) as posed at rest: what
// reaches (`end`, in its last bone's frame), its own joints at its end (`ends`), and how it bends
// (LegRig).
leg_measure :: proc(pose: Pose, chain: []u32, end: [3]f32, ends: u32 = 0) -> (leg: LegRig) {
  leg.end, leg.ends = end, ends
  if len(chain) < 2 do return
  last := chain[len(chain) - 1]
  tip := bone_point(pose, last, end)
  reaching := len(chain) - min(int(ends), len(chain) - 1)
  leg.middle = ik_chain_middle(pose, chain, end, reaching)
  for k in 1 ..< len(chain) do leg.length += linalg.length(pose.positions[chain[k]] - pose.positions[chain[k - 1]])
  leg.length += linalg.length(tip - pose.positions[last])
  if leg.middle == 0 do return
  bone := chain[leg.middle]
  at := pose.positions[bone]
  above := pose.positions[chain[leg.middle - 1]]
  leg.line = linalg.normalize0(tip - above)
  off := (at - above) - linalg.dot(at - above, leg.line) * leg.line
  if linalg.length(off) > 1e-3 * leg.length {
    leg.bend = linalg.normalize(off)
    return
  }
  // straight at rest: the side its stops let it bend (a knee forward, a hock back)
  d := tip - at
  l := limit_of(pose, bone)
  for axis in 0 ..< 3 {
    if l.lo[axis] == l.hi[axis] do continue
    e: [3]f32
    e[axis] = 1
    a := linalg.mul(pose.rotations[bone], e)
    if abs(linalg.dot(a, linalg.normalize0(d))) >= 0.7 do continue
    // turning about a by +θ swings the end along a × d, and the joint itself out the other way
    lo, hi := l.lo[axis], l.hi[axis]
    if lo <= -math.F32_MAX do lo, hi = 0, 0
    side := f32(-1) if lo + hi < 0 else 1
    leg.bend = -side * linalg.normalize(linalg.cross(a, d))
    return
  }
  return
}

// leg_pole is the point `leg`'s chain bends toward, reaching for `target`, as posed: off the middle
// of the line from the joint above its middle one to the target, by the chain's length, the way it
// bends at rest, turned with the body (`turn`: how the skeleton's root is turned from rest) and swung
// as the limb swings (the shortest turn from its line at rest to the line to the target). It goes
// where the target goes, so the bend never flips as a foot steps far ahead or back, and an arm
// hanging with its elbow back, swung forward to punch, has its elbow down. Straight back against
// its rest line the swing has no one way to go: the bend is then only turned with the body.
// `swivel` (radians) then turns the bend about that line: an elbow flared, a knee swung out.
leg_pole :: proc(leg: LegRig, pose: Pose, chain: []u32, target: [3]f32, swivel: f32 = 0, turn := linalg.QUATERNIONF32_IDENTITY) -> [3]f32 {
  if leg.middle == 0 do return target
  above := pose.positions[chain[leg.middle - 1]]
  bend := linalg.mul(turn, leg.bend)
  from, to := linalg.mul(turn, leg.line), linalg.normalize0(target - above)
  if linalg.dot(from, to) > -0.99 && to != 0 do bend = linalg.mul(linalg.quaternion_between_two_vector3(from, to), bend)
  if swivel != 0 && to != 0 do bend = linalg.mul(linalg.quaternion_angle_axis(swivel, to), bend)
  return (above + target) / 2 + bend * leg.length
}

// leg_reach bends `leg`'s chain so its end reaches `target`, toward its pole (leg_pole), within
// its joints' stops; the end's own joints keep their turns, or with `face` (not 0) turn it to face
// that way in skeleton space (a planted foot), giving last.
leg_reach :: proc(pose: Pose, chain: []u32, leg: LegRig, target: [3]f32, swivel: f32 = 0, turn := linalg.QUATERNIONF32_IDENTITY, face: quaternion128 = 0, iterations := 16) {
  ik_solve(pose, chain, {
    target      = target,
    pole        = leg_pole(leg, pose, chain, target, swivel, turn),
    pole_weight = 1,
    iterations  = iterations,
    end         = leg.end,
    ends        = leg.ends,
    hold        = face != 0,
    face        = face,
    middle      = leg.middle,
  })
}
