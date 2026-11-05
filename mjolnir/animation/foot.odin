package animation

import "../geometry"
import "core:math"
import "core:math/linalg"

// Ground contact: how a leg's end that stands on the ground (a foot) meets it, whatever the leg (a
// human's, a dog's, a strider's, a mech's). The caller only moves where the foot goes; three rules
// then place it, all measured from the foot's own shape (its corners: the points of its pieces, in
// its bones' frames):
//
//   1. Its facing is exact: the foot is placed first, the leg reaches its pivot (the foot's first
//      own joint, LegRig.ends), then the foot's own joints turn it to that facing, within their
//      stops.
//   2. It keeps its rest angle to the leg: the facing its own joints give it, swung as the line
//      from the leg's root to the target swings from where it was at rest. A leg reaching ahead tips
//      its toes up, one under the body stands flat, one behind tips them down. Its ball and toes
//      follow its heel on the ground (`trail`, `toes_trail`: how far behind the target they are,
//      read with lag_sample or lag_read): its ball stands as high as its target stood a moment
//      before, its toes turn as it turned a moment before that, so rising its heel lifts first and
//      its toes stay flat, landing its heel comes down first and its ball, then its toes, still up,
//      come down after it. A still pose has no trail.
//   3. It rests on the ground: tipped about the corner it then stands on (its lowest), so nothing
//      of it goes through the ground and, ahead, it lands on its heel and the ground lays it flat;
//      behind it stands flat too (tipping toes down, about its toes' tips, only as a target lifting
//      lets it). Its heel lifts as the leg runs out of reach: nearing the furthest the leg reaches
//      its pivot (FootRig.stretch) it rolls on the edge toward the leg, as little as keeps the pivot
//      within reach, the toes flat; pulled further (out of rolls, or a reach that way shorter) the
//      leg lifts it off the ground, toes and all.
//      Joints below the foot (toes) lie flat on the ground as they near it, and never go through.
//
// The heel, the ball and the toes are not named anywhere: they are the corners the foot turns on.
// The ground is level, at a height (`ground`, skeleton space).

// BoneCorner is a point of a bone's shape, in its frame: what foot_measure reads a foot's
// corners from.
BoneCorner :: struct {
  bone: u32,
  at:   [3]f32,
}

// FootConform is a joint below a foot (a toe): bone `bone` turning about `axis`, with its corners
// corners[first:][:count] in the bone's frame. `down` is the world's down at rest, in the bone's
// frame (level: it points down again); `height` is how tall its corners stand at rest, the height
// over the ground at which it starts lying down.
FootConform :: struct {
  bone:         u32,
  axis:         int,
  first, count: int,
  down:         [3]f32,
  height:       f32,
}

// FootRig is what foot_measure reads off a leg's foot at rest: its pivot (its first own joint, in
// its last bone's frame); the way from the leg's root to its end (`reach`) and how the foot faced
// (`face`), skeleton space, and its own joints' turns then (`own`); `toes` the way from its pivot to
// the joints below it (its frame; 0 for none); `span` how far ahead of its heel the first of those
// is (level); `roll` how far it rolls on an edge at most; `stretch` how far from the leg's root its
// pivot is when its heel starts to lift and the furthest it reaches; `rest_height` how high its end
// stood over the ground at rest. Its own corners are corners[corners_first:][:corners_count], the
// joints below it lying on the ground conforms[conform_first:][:conform_count] (foot_measure's
// arrays).
FootRig :: struct {
  pivot, reach, toes:           [3]f32,
  face, own:                    quaternion128,
  roll, span:                   f32,
  stretch:                      [2]f32,
  rest_height:                  f32,
  corners_first, corners_count: int,
  conform_first, conform_count: int,
}

// foot_turns is the axes bone `b`'s joint turns about, and its stops on them: 0 where it is free.
@(private = "file")
foot_turns :: proc(pose: Pose, b: u32) -> (turns: bit_set[0 ..< 3], lo, hi: [3]f32) {
  l := limit_of(pose, b)
  for axis in 0 ..< 3 {
    if l.lo[axis] == l.hi[axis] do continue
    turns += {axis}
    if l.lo[axis] > -math.F32_MAX do lo[axis], hi[axis] = l.lo[axis], l.hi[axis]
  }
  return
}

// foot_measure reads, from `pose` at rest, what ground contact needs of `leg`'s foot (FootRig): the
// foot is the leg's last bone, its own joints the leg's `ends` (none: no foot). `corners` are the
// points of the bones' shapes; the foot's and those of the joints below it that lie down on the
// ground are appended to `out_corners`, those joints to `out_conforms`. `ground` is the ground's
// height at rest.
foot_measure :: proc(pose: Pose, chain: []u32, leg: LegRig, corners: []BoneCorner, out_corners: ^[dynamic][3]f32, out_conforms: ^[dynamic]FootConform, ground: f32 = 0) -> (foot: FootRig) {
  n := len(chain)
  turning := n - int(leg.ends)
  if leg.ends == 0 || turning < 1 do return
  tip := chain[n - 1]
  into :: proc(pose: Pose, bone: u32, p: [3]f32) -> [3]f32 {
    return linalg.mul(linalg.quaternion_inverse(pose.rotations[bone]), p - pose.positions[bone])
  }
  end := bone_point(pose, tip, leg.end)
  foot.rest_height = end.y - ground
  foot.face = pose.rotations[tip]
  foot.own = linalg.QUATERNIONF32_IDENTITY
  for b in chain[turning:] do foot.own *= pose.local[b].rotation
  foot.pivot = into(pose, tip, pose.positions[chain[turning]])
  foot.reach = linalg.normalize0(end - pose.positions[chain[0]])
  foot.corners_first = len(out_corners)
  // (every corner its bone carries: a hinge's lugs ahead of it too)
  for c in corners do if c.bone == tip do append(out_corners, c.at)
  foot.corners_count = len(out_corners) - foot.corners_first
  // the bones below the foot's, parents first
  below := make([]bool, len(pose.parents), context.temp_allocator)
  below[tip] = true
  foot.conform_first = len(out_conforms)
  for b in pose.order {
    p := pose.parents[b]
    if p < 0 || !below[p] do continue
    below[b] = true
    turns, _, _ := foot_turns(pose, b)
    if turns == {} do continue
    cf := FootConform{bone = b, first = len(out_corners)}
    for axis in turns {
      cf.axis = axis
      break
    }
    lo, hi := f32(math.F32_MAX), f32(-math.F32_MAX)
    for c in corners do if c.bone == b {
      append(out_corners, c.at)
      y := (pose.positions[b] + linalg.mul(pose.rotations[b], c.at)).y
      lo, hi = min(lo, y), max(hi, y)
    }
    cf.count = len(out_corners) - cf.first
    if cf.count == 0 do continue
    cf.down = linalg.mul(linalg.quaternion_inverse(pose.rotations[b]), [3]f32{0, -1, 0})
    cf.height = max(hi - lo, 1e-3)
    append(out_conforms, cf)
  }
  foot.conform_count = len(out_conforms) - foot.conform_first
  conforms := out_conforms[foot.conform_first:][:foot.conform_count]
  for cf in conforms do foot.toes += into(pose, tip, pose.positions[cf.bone]) - foot.pivot
  foot.toes = linalg.normalize0(foot.toes)
  // how far ahead of its heel (its corner furthest back, level) its first joint below it (the ball)
  // is: the lever its ball follows its heel on
  if foot.conform_count > 0 {
    ball := pose.positions[conforms[0].bone]
    if way := linalg.mul(pose.rotations[tip], foot.toes); way.xz != 0 {
      way.y = 0
      way = linalg.normalize(way)
      for c in out_corners[foot.corners_first:][:foot.corners_count] do foot.span = max(foot.span, linalg.dot(ball - (pose.positions[tip] + linalg.mul(pose.rotations[tip], c)), way))
    }
  }
  // the furthest the leg reaches from its root to its pivot, within its stops: pulled out the way
  // it reaches at rest a little at a time, each pull from the last, so it unfolds the way it folds
  // (then put back as it was)
  {
    reaching := chain[:turning + 1]
    kept := make([]geometry.Transform, len(reaching), context.temp_allocator)
    for b, k in reaching do kept[k] = pose.local[b]
    root := pose.positions[chain[0]]
    way := linalg.normalize0(pose.positions[chain[turning]] - root)
    rest := linalg.length(pose.positions[chain[turning]] - root)
    furthest := rest
    for _ in 0 ..< 40 {
      ik_solve(pose, reaching, {target = root + way * (furthest + 0.02 * leg.length), iterations = 16})
      far := linalg.length(pose.positions[chain[turning]] - root)
      if far < furthest + 1e-4 * leg.length do break
      furthest = far
    }
    // its heel starts up a little before that: no nearer than it stands at rest (flat)
    foot.stretch = {max(rest, furthest - 0.05 * leg.length), furthest}
    for b, k in reaching do pose.local[b] = kept[k]
    if p := pose.parents[chain[0]]; p >= 0 {
      moved := make([]bool, len(pose.parents), context.temp_allocator)
      moved[p] = true
      pose_propagate(pose, moved)
    } else do pose_compose(pose)
  }
  // it rolls on an edge as far as the joints below it can turn back to lie on the ground
  foot.roll = 1.2
  for cf in conforms {
    l := limit_of(pose, cf.bone)
    if l.lo[cf.axis] > -math.F32_MAX do foot.roll = min(foot.roll, abs(l.lo[cf.axis]), abs(l.hi[cf.axis]))
  }
  return
}

// foot_solve poses `leg`'s chain for `target` (where its end goes, skeleton space; its ball's and
// its toes' trailing it by `trail` and `toes_trail`) by the contact rules above, its knee swung by
// `swivel` and the body turned by `turn` (leg_pole), on the ground at height `ground`. `corners` and
// `conforms` are foot_measure's arrays. `toes` is how far up its toes stand from lying on the
// ground, following: foot_conform's `up`, once the leg's descendants are posed.
foot_solve :: proc(pose: Pose, chain: []u32, leg: LegRig, foot: FootRig, corners: [][3]f32, conforms: []FootConform, target, trail, toes_trail: [3]f32, swivel: f32 = 0, turn := linalg.QUATERNIONF32_IDENTITY, ground: f32 = 0) -> (toes: f32) {
  n := len(chain)
  turning := n - int(leg.ends)
  tip := chain[n - 1]
  pivot := chain[turning]
  own_corners := corners[foot.corners_first:][:foot.corners_count]
  // the limb first swung whole toward the target by the joints above its middle one (within their
  // stops), its shape kept: the solve then starts from the way of folding it ends near, the one the
  // target leads it to, and never jumps between two as the target moves (a dog's hock, a strider)
  if leg.middle > 1 {
    upper := chain[:leg.middle]
    last := upper[len(upper) - 1]
    end := pose.positions[tip] + linalg.mul(pose.rotations[tip], leg.end)
    ik_solve(pose, upper, {
      target     = target,
      end        = linalg.mul(linalg.quaternion_inverse(pose.rotations[last]), end - pose.positions[last]),
      iterations = 8,
    })
    moved := make([]bool, len(pose.parents), context.temp_allocator)
    moved[chain[0]] = true
    pose_propagate(pose, moved)
  }
  // 2. the facing its own joints give it on the rest stance, swung with the limb (what the chain
  // above it is turned by is IK's to undo)
  turned := linalg.QUATERNIONF32_IDENTITY
  for b in chain[turning:] do turned *= pose.local[b].rotation
  facing := linalg.normalize(turn * foot.face * linalg.quaternion_inverse(foot.own) * turned)
  from := linalg.mul(turn, foot.reach)
  to := linalg.normalize0(target - pose.positions[chain[0]])
  swing := linalg.QUATERNIONF32_IDENTITY
  if to != 0 && linalg.dot(from, to) > -0.99 do swing = linalg.quaternion_between_two_vector3(from, to)
  // its toes follow its heel on the ground (`trail`, how far behind its target theirs is): they
  // stand as high over its end as its target stood a moment before, so rising its heel lifts first
  // and its toes stay down, and coming down it lands on its heel, toes still up, that roll down
  // after it. Its pitch (the swing's turn about its side) is then that, not the limb's, no further
  // than it rolls (past that its toes let go and follow), and the ground does not lay it flat: it
  // stands on whichever of its corners is down, heel or ball (below). It follows as its heel or its
  // toes near the ground, wholly on it, not at all once both stand as high as its toes can stay
  // down for (rolled as far as it rolls); in the air it keeps the limb's.
  follows := false
  if way := linalg.mul(facing, foot.toes); way.xz != 0 && trail != 0 && foot.span > 0 {
    way.y = 0
    side := linalg.normalize(linalg.cross([3]f32{0, 1, 0}, way))
    if swing.w < 0 do swing = -swing
    limb := 2 * math.atan2(linalg.dot([3]f32{swing.x, swing.y, swing.z}, side), swing.w)
    follow := clamp(math.atan2(-trail.y, foot.span), -foot.roll, foot.roll)
    low := min(target.y, target.y + trail.y) - ground - foot.rest_height
    k := clamp(1 - low / (foot.span * math.sin(min(foot.roll, math.PI / 4))), 0, 1)
    if k > 0 {
      // its toes, a link further on, turn as it turned a moment before (a tail's next link): up
      // from level by its pitch then, its ball's target over its toes', so landing they still point
      // up once its ball is down, and settle after
      toes = k * k * (3 - 2 * k) * clamp(math.atan2((toes_trail - trail).y, foot.span), -foot.roll, foot.roll)
      // (from what the limb gives it unfollowed: toes down no further than it rolls, below)
      pitch := math.lerp(min(limb, foot.roll), follow, k * k * (3 - 2 * k))
      swing = linalg.quaternion_angle_axis(pitch, side) * swing * linalg.quaternion_inverse(linalg.quaternion_angle_axis(limb, side))
      follows = true
    }
  }
  x := Placed{target - linalg.mul(facing, leg.end), facing}
  // 3. swung about its end, as far as the ground lets it: coming down ahead it lands on its heel
  // and the ground lays it flat as the target comes down; on the ground it stands flat
  // (out of the ground first: a body pitching may tip it in)
  at := target
  lift := max(-lowest(x, own_corners, ground), 0)
  x.position.y += lift
  at.y += lift
  rolled: f32 = 0
  // the share of the swing tipping it toward the joints below it (toes down: behind the body), about
  // its end, as far as the ground lets the whole of it (the joints below it as they hang from it, so
  // it tips about the tips of its toes) and no further than it rolls: on the ground behind it stands
  // flat (its heel lifts only as the limb runs out of reach, below), lifted it tips as its height
  // lets it, so it tips smoothly as it leaves the ground
  if way := linalg.mul(x.rotation, foot.toes); foot.toes != 0 && way.xz != 0 && !follows {
    way.y = 0
    axis := linalg.normalize(linalg.cross([3]f32{0, 1, 0}, way))
    if swing.w < 0 do swing = -swing
    if pitch := 2 * math.atan2(linalg.dot([3]f32{swing.x, swing.y, swing.z}, axis), swing.w); pitch > 0 {
      swing *= linalg.quaternion_inverse(linalg.quaternion_angle_axis(pitch, axis))
      whole := make([dynamic][3]f32, 0, len(own_corners), context.temp_allocator)
      append(&whole, ..own_corners)
      from_tip := linalg.quaternion_inverse(pose.rotations[tip])
      for cf in conforms[foot.conform_first:][:foot.conform_count] {
        for c in corners[cf.first:][:cf.count] do append(&whole, linalg.mul(from_tip, point_on({pose.positions[cf.bone], pose.rotations[cf.bone]}, c) - pose.positions[tip]))
      }
      in_, out := f32(0), min(pitch, foot.roll)
      if lowest(turn_about(x, at, linalg.quaternion_angle_axis(out, axis)), whole[:], ground) >= 0 do in_ = out
      else do for _ in 0 ..< 20 {
        mid := (in_ + out) / 2
        if lowest(turn_about(x, at, linalg.quaternion_angle_axis(mid, axis)), whole[:], ground) < 0 do out = mid
        else do in_ = mid
      }
      rolled = in_
      x = turn_about(x, at, linalg.quaternion_angle_axis(rolled, axis))
    }
  }
  if !follows && lowest(turn_about(x, at, swing), own_corners, ground) < 0 {
    in_, out := f32(0), f32(1)
    for _ in 0 ..< 20 {
      mid := (in_ + out) / 2
      if lowest(turn_about(x, at, linalg.quaternion_slerp(linalg.QUATERNIONF32_IDENTITY, swing, mid)), own_corners, ground) < 0 do out = mid
      else do in_ = mid
    }
    swing = linalg.quaternion_slerp(linalg.QUATERNIONF32_IDENTITY, swing, in_)
  }
  x = turn_about(x, at, swing)
  // following, it stands on the corner that is down, lifted out of the ground on it
  if follows do x.position.y += max(-lowest(x, own_corners, ground), 0)
  // and back down as far as the ground lets it
  x.position.y -= clamp(lowest(x, own_corners, ground), 0, lift)
  // near the furthest the leg reaches (foot.stretch, from its root to its pivot), on the ground: it
  // rolls on its edge toward the leg's root (its heel lifting, its toes staying down) as little as
  // keeps its pivot within reach, the heel starting up a little before the limb is straight (from
  // stretch[0], easing into the furthest) so it lifts smoothly however fast the target goes back
  h := Holding{x = x, hold = leg.end, at = point_on(x, leg.end)}
  root := pose.positions[chain[0]]
  if foot.stretch[1] > 0 && lowest(x, own_corners, ground) < 0.05 * leg.length {
    soft, band := foot.stretch[0], foot.stretch[1] - foot.stretch[0]
    if far := linalg.length(point_on(x, foot.pivot) - root); far > soft {
      within := soft + (band * math.tanh((far - soft) / band) if band > 1e-6 else 0)
      angle: f32
      h.x, h.at, angle = foot_roll(x, own_corners, foot.pivot, root, within, 0.05 * leg.length, foot.roll - rolled, ground)
      h.hold = linalg.mul(linalg.quaternion_inverse(h.x.rotation), h.at - h.x.position)
      rolled += angle
    }
  }
  // 1. the foot's own joints turn it to that facing, within their stops, and the whole chain reaches
  // with what holds it, its end on the target, turning toward that facing too
  foot_hold(pose, chain, leg, h, swivel, turn, 16)
  // still stretched on the ground (the end falls short: a reach that way shorter than the furthest):
  // it rolls on further as little as brings its pivot back within the reach the chain got, and a
  // little more (a straight limb has no side to bend to; no more than it fell short), and that edge
  // holds it. Past the furthest it rolls, the limb pulls it off the ground, toes and all (below).
  reached := point_on({pose.positions[tip], pose.rotations[tip]}, h.hold)
  if short := linalg.length(reached - h.at); short > 1e-3 * leg.length && lowest(h.x, own_corners, ground) < 0.05 * leg.length {
    reach := linalg.length(pose.positions[pivot] - root) - min(short, 0.02 * leg.length)
    h.x, h.at, _ = foot_roll(h.x, own_corners, foot.pivot, root, reach, 0.05 * leg.length, foot.roll - rolled, ground)
    h.hold = linalg.mul(linalg.quaternion_inverse(h.x.rotation), h.at - h.x.position)
    foot_hold(pose, chain, leg, h, swivel, turn, 16)
  }
  // the contact is exact, the facing as near as the stops let it: a round or two more settle the two
  for _ in 0 ..< 2 {
    if off := pose.rotations[tip] * linalg.quaternion_inverse(h.x.rotation); abs(off.w) > 0.99999 do break
    foot_hold(pose, chain, leg, h, swivel, turn, 8)
  }
  // where the leg can't turn it to its facing (no joint of a strider's leg rolls its foot as the
  // leg splays, or a limb pulled past the furthest it rolls), it stands on the edge it ends on,
  // lifted out of the ground, the joints below it too, as far as their stops let them lie down
  if low := min(lowest({pose.positions[tip], pose.rotations[tip]}, own_corners, ground), conform_lowest(pose, chain, foot, corners, conforms, ground)); low < -1e-3 * leg.length {
    h.at.y -= low
    foot_hold(pose, chain, leg, h, swivel, turn, 8)
  }
  return
}

// Placed is a frame placed in skeleton space: a bone's, or where a foot is to go.
@(private = "file")
Placed :: struct {
  position: [3]f32,
  rotation: quaternion128,
}

// conform_lowest is how high the leg's joints below its foot (toes) would stand at the lowest over
// the ground, laid on it from the foot as posed (foot_conform), their turns kept; MAX with none.
@(private = "file")
conform_lowest :: proc(pose: Pose, chain: []u32, foot: FootRig, corners: [][3]f32, conforms: []FootConform, ground: f32) -> f32 {
  own := conforms[foot.conform_first:][:foot.conform_count]
  if len(own) == 0 do return math.F32_MAX
  kept := make([]quaternion128, len(own), context.temp_allocator)
  for cf, k in own do kept[k] = pose.local[cf.bone].rotation
  moved := make([]bool, len(pose.parents), context.temp_allocator)
  moved[chain[len(chain) - 1]] = true
  pose_propagate(pose, moved)
  foot_conform(pose, foot, corners, conforms, ground = ground)
  low := f32(math.F32_MAX)
  for cf in own do for c in corners[cf.first:][:cf.count] do low = min(low, point_on({pose.positions[cf.bone], pose.rotations[cf.bone]}, c).y - ground)
  for cf, k in own do pose.local[cf.bone].rotation = kept[k]
  pose_propagate(pose, moved)
  return low
}

// Holding is how a foot is held: placed `x` (its last bone's frame), point `hold` of it (in that
// frame) at `at`.
@(private = "file")
Holding :: struct {
  x:        Placed,
  hold, at: [3]f32,
}

// foot_hold turns the foot's own joints to its facing (h.x), within their stops, and reaches the
// whole leg to put h.hold on h.at in `iterations`, turning toward that facing too, the own joints
// with it (a hinged ankle can't level a foot on a splayed leg: the hip turns it).
@(private = "file")
foot_hold :: proc(pose: Pose, chain: []u32, leg: LegRig, h: Holding, swivel: f32, turn: quaternion128, iterations: int) {
  own := chain[len(chain) - int(leg.ends):]
  up := pose.rotations[pose.parents[own[0]]]
  for b, k in own {
    after := linalg.QUATERNIONF32_IDENTITY
    for j in own[k + 1:] do after *= pose.local[j].rotation
    local := linalg.quaternion_inverse(up) * h.x.rotation * linalg.quaternion_inverse(after)
    rest := pose.rest[b].rotation
    pose.local[b].rotation = joint_rotation(rest, joint_angles(rest, local), limit_of(pose, b))
    up *= pose.local[b].rotation
  }
  moved := make([]bool, len(pose.parents), context.temp_allocator)
  moved[pose.parents[own[0]]] = true
  pose_propagate(pose, moved)
  ik_solve(pose, chain, {
    target      = h.at,
    pole        = leg_pole(leg, pose, chain, h.at, swivel, turn),
    pole_weight = 1,
    iterations  = iterations,
    end         = h.hold,
    ends        = leg.ends,
    hold        = true,
    face        = h.x.rotation,
    middle      = leg.middle,
  })
}

// foot_conform lays the joints below `foot` (its toes, foot_measure's conforms) on the ground at
// height `ground` as they near it, and keeps them out of it, within their stops; the bones below
// each follow. The first stands `up` from level (tips up: following, foot_solve's `toes`). Run it
// once the leg's descendants are posed.
foot_conform :: proc(pose: Pose, foot: FootRig, corners: [][3]f32, conforms: []FootConform, up: f32 = 0, ground: f32 = 0) {
  moved := make([]bool, len(pose.parents), context.temp_allocator)
  own := conforms[foot.conform_first:][:foot.conform_count]
  for cf in own {
    c := Conforming{pose, cf, corners, joint_angles(pose.rest[cf.bone].rotation, pose.local[cf.bone].rotation), ground}
    l := limit_of(pose, cf.bone)
    lo, hi := l.lo[cf.axis], l.hi[cf.axis]
    now := c.angles[cf.axis]
    if lo <= -math.F32_MAX do lo, hi = now - math.PI, now + math.PI
    // level: its rest down pointing down again; it lies down as it nears the ground
    level := minimize(lo, hi, &c, proc(data: rawptr, a: f32) -> f32 {
      c := (^Conforming)(data)
      return linalg.mul(conform_turn(c^, a), c.cf.down).y
    })
    // following, the first of them stands `up` from level (tips up): turned the way that lifts its
    // corner furthest out
    if up != 0 && cf.bone == own[0].bone {
      far := cf.first
      for k in cf.first ..< cf.first + cf.count do if linalg.length(corners[k]) > linalg.length(corners[far]) do far = k
      tip :: proc(c: Conforming, a: f32, corner: [3]f32) -> f32 {
        return linalg.mul(conform_turn(c, a), corner).y
      }
      way: f32 = 1 if tip(c, level + 0.01, corners[far]) > tip(c, level - 0.01, corners[far]) else -1
      level = clamp(level + way * up, lo, hi)
    }
    a := math.lerp(now, level, clamp(1 - conform_low(c, level) / cf.height, 0, 1))
    // never through the ground: the least turn that lifts it out, toward either stop
    if conform_low(c, a) < 0 {
      best, gap := a, f32(math.F32_MAX)
      for end in ([2]f32{lo, hi}) {
        if conform_low(c, end) < 0 do continue
        in_, out := a, end
        for _ in 0 ..< 24 {
          mid := (in_ + out) / 2
          if conform_low(c, mid) < 0 do in_ = mid
          else do out = mid
        }
        if abs(out - a) < gap do best, gap = out, abs(out - a)
      }
      a = best
    }
    c.angles[cf.axis] = a
    pose.local[cf.bone].rotation = joint_rotation(pose.rest[cf.bone].rotation, c.angles, l)
    p := pose.parents[cf.bone]
    moved[p] = true
    pose_propagate(pose, moved)
    moved[p] = false
  }
}

// Conforming is a joint below a foot being laid on the ground: its turns, on its parent as posed.
@(private = "file")
Conforming :: struct {
  pose:    Pose,
  cf:      FootConform,
  corners: [][3]f32,
  angles:  [3]f32,
  ground:  f32,
}

// conform_turn is how the conforming joint faces, turned `a` about its axis.
@(private = "file")
conform_turn :: proc(c: Conforming, a: f32) -> quaternion128 {
  angles := c.angles
  angles[c.cf.axis] = a
  b := c.cf.bone
  return c.pose.rotations[c.pose.parents[b]] * joint_rotation(c.pose.rest[b].rotation, angles, limit_of(c.pose, b))
}

// conform_low is how high over the ground the conforming joint's lowest corner stands, turned `a`.
@(private = "file")
conform_low :: proc(c: Conforming, a: f32) -> f32 {
  b := c.cf.bone
  p := c.pose.parents[b]
  turn := conform_turn(c, a)
  at := c.pose.positions[p] + linalg.mul(c.pose.rotations[p], c.pose.local[b].position)
  low := f32(math.F32_MAX)
  for k in c.corners[c.cf.first:][:c.cf.count] do low = min(low, (at + linalg.mul(turn, k)).y - c.ground)
  return low
}

// foot_roll rolls foot `x` when its pivot (`pivot`, in its frame) is out of reach, `reach` from the
// leg's root (`root`) at most: on the edge it stands on (its corners within `tolerance` of its
// lowest) toward the root, the way the limb pulls it, about that edge (its line; a lone corner,
// square to the pull), as little as brings the pivot within reach (rolling lifts it toward the
// root), `most` at most. `on`, the edge's middle, is what holds it; `angle` how far it rolled.
@(private = "file")
foot_roll :: proc(x: Placed, corners: [][3]f32, pivot, root: [3]f32, reach, tolerance, most, ground: f32) -> (rolled: Placed, on: [3]f32, angle: f32) {
  at := point_on(x, pivot)
  way := root - at
  way.y = 0
  if linalg.length(way) < 1e-6 do return x, at, 0
  way = linalg.normalize(way)
  low := lowest(x, corners, ground)
  // the edge: the corners it stands on furthest that way, within a quarter of how far they spread
  near, far := f32(math.F32_MAX), f32(-math.F32_MAX)
  for c in corners {
    p := point_on(x, c)
    if p.y - ground > low + tolerance do continue
    d := linalg.dot(p, way)
    near, far = min(near, d), max(far, d)
  }
  edge := make([dynamic][3]f32, context.temp_allocator)
  for c in corners {
    p := point_on(x, c)
    if p.y - ground <= low + tolerance && linalg.dot(p, way) >= far - max(tolerance, 0.25 * (far - near)) {
      append(&edge, p)
      on += p
    }
  }
  on /= f32(len(edge))
  // its line: its two corners furthest apart, turned to lift the pivot
  axis := linalg.cross([3]f32{0, 1, 0}, way)
  span: f32 = 0
  for p in edge do for q in edge {
    d := q - p
    d.y = 0
    if l := linalg.length(d); l > span && l > tolerance do span, axis = l, d
  }
  axis = linalg.normalize(axis)
  if linalg.cross(axis, at - on).y < 0 do axis = -axis
  from_root :: proc(on, at, root, axis: [3]f32, a: f32) -> f32 {
    return linalg.length(on + linalg.mul(linalg.quaternion_angle_axis(a, axis), at - on) - root)
  }
  lo, hi := f32(0), max(most, 0)
  if from_root(on, at, root, axis, hi) > reach do lo = hi
  else do for _ in 0 ..< 24 {
    mid := (lo + hi) / 2
    if from_root(on, at, root, axis, mid) > reach do lo = mid
    else do hi = mid
  }
  return turn_about(x, on, linalg.quaternion_angle_axis(hi, axis)), on, hi
}

// turn_about is `x` turned by `q` about point `p`.
@(private = "file")
turn_about :: proc(x: Placed, p: [3]f32, q: quaternion128) -> Placed {
  return {p + linalg.mul(q, x.position - p), linalg.normalize(q * x.rotation)}
}

// lowest is how high over the ground at `ground` the lowest of `corners` (in frame `x`) stands.
@(private = "file")
lowest :: proc(x: Placed, corners: [][3]f32, ground: f32) -> f32 {
  low := f32(math.F32_MAX)
  for c in corners do low = min(low, point_on(x, c).y - ground)
  return low
}

// point_on is point `p` of frame `x`, in the space `x` is in.
@(private = "file")
point_on :: proc(x: Placed, p: [3]f32) -> [3]f32 {
  return x.position + linalg.mul(x.rotation, p)
}

// minimize is where `f` is least on [lo, hi]: the best of a coarse sweep, refined by golden section.
@(private = "file")
minimize :: proc(lo, hi: f32, data: rawptr, f: proc(data: rawptr, a: f32) -> f32) -> f32 {
  STEPS :: 16
  best, at := f32(math.F32_MAX), lo
  for k in 0 ..= STEPS {
    a := lo + (hi - lo) * f32(k) / STEPS
    if v := f(data, a); v < best do best, at = v, a
  }
  step := (hi - lo) / STEPS
  a, b := max(lo, at - step), min(hi, at + step)
  G :: 0.618034
  for _ in 0 ..< 20 {
    c, d := b - G * (b - a), a + G * (b - a)
    if f(data, c) < f(data, d) do b = d
    else do a = c
  }
  return (a + b) / 2
}
