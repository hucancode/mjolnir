package animation

import "../geometry"
import "core:math"
import "core:math/linalg"

// TailParams makes a chain lag behind its parent like a tail on a spring. Its layer's bones
// are the chain, head first (bone_chain_down; reverse it when the rig's root is the tip).
TailParams :: struct {
  stiffness: f32, // 0..1: higher catches up and oscillates faster
  damping:   f32, // damping ratio: 1 = critical (no overshoot), 0 = undamped, >1 overdamped
  stretch:   bool, // bones may stretch (pure spring); false = rigid hinge chain
}

// A tail bone's state, world space: where its root lags to and how fast it moves.
@(private = "file")
TailBone :: struct {
  position, velocity: [3]f32,
}

@(private)
TAIL_STATE :: size_of(TailBone) / size_of(f32)

// Spring stiffness at stiffness = 1.
@(private = "file")
TAIL_MAX_STIFFNESS :: f32(200.0)

// Largest step the tail spring integrates at once; longer frames are clamped
// so the explicit integration stays stable after a hitch.
@(private = "file")
TAIL_MAX_STEP :: f32(1.0 / 30.0)

// Each child bone's world position springs toward its parent's tip; bones then aim down the
// lagged chain. State is world space so moving the rig and turning its bones both drag it.
@(private)
tail_apply :: proc(pose: Pose, bones: []u32, state: []f32, params: TailParams, delta_time: f32, fresh: bool) {
  n := len(bones)
  if n < 2 do return
  tail := ([^]TailBone)(raw_data(state))[:n]
  dt := min(delta_time, TAIL_MAX_STEP)
  stiffness := TAIL_MAX_STIFFNESS * clamp(params.stiffness, 0.0, 1.0)
  damping := 2.0 * math.sqrt(stiffness) * params.damping
  for i in 1 ..< n {
    bone, parent := bones[i], bones[i - 1]
    s := &tail[i]
    length := pose.lengths[bone]
    parent_world := to_world(pose, pose.positions[parent])
    up := geometry.qy(pose.rotations[parent])
    up_world := linalg.normalize((pose.root_world * [4]f32{up.x, up.y, up.z, 0}).xyz)
    tip_world := parent_world + up_world * length
    if fresh do s.position = tip_world
    s.velocity += ((tip_world - s.position) * stiffness - s.velocity * damping) * dt
    s.position += s.velocity * dt
    if !params.stretch {
      delta := s.position - parent_world
      if d := linalg.length(delta); d > 0.001 {
        radial := delta / d
        s.position = parent_world + radial * length
        // drop the radial velocity so the spring does not fight the constraint each frame
        s.velocity -= radial * linalg.dot(s.velocity, radial)
      }
    }
    pose.positions[bone] = to_model(pose, s.position)
  }
  for i in 0 ..< n - 1 do aim_bone(pose, bones[i], pose.positions[bones[i + 1]] - pose.positions[bones[i]])
  // the last bone continues the chain instead of snapping back to its incoming orientation
  aim_bone(pose, bones[n - 1], pose.positions[bones[n - 1]] - pose.positions[bones[n - 2]])
}
