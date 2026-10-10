package mjolnir

import "render"
import "render/debug_line"
import anim "animation"
import "core:math/linalg"

DEBUG_BONE_PALETTE :: [6][4]f32 {
  {1.0, 0.0, 0.0, 1.0},
  {0.0, 1.0, 0.0, 1.0},
  {0.0, 0.0, 1.0, 1.0},
  {1.0, 1.0, 1.0, 1.0},
  {1.0, 0.5, 0.0, 1.0},
  {0.0, 1.0, 1.0, 1.0},
}

// Draw an animator's current pose as debug lines, colored by bone depth.
// root_world places the skeleton in the world (usually the skinned node's matrix).
debug_skeleton :: proc(
  engine: ^Engine,
  skel: ^anim.Skeleton,
  animator: ^anim.Animator,
  root_world: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
  bypass_depth: bool = true,
  life: f32 = 0,
) {
  bone_segments := anim.bone_segments(animator, skel, root_world, context.temp_allocator)
  if len(bone_segments) == 0 do return
  exp := debug_line.resolve_expiry(time_since_start(engine), life)
  palette := DEBUG_BONE_PALETTE
  segs := make([]debug_line.Segment, len(bone_segments), context.temp_allocator)
  for s, i in bone_segments {
    segs[i] = {
      a            = s.from,
      b            = s.to,
      color        = palette[s.depth % u32(len(palette))],
      expiry       = exp,
      bypass_depth = bypass_depth,
    }
  }
  render.debug_segments(&engine.render, ..segs)
}
