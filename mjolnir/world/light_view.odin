package world

// Neutral, render-agnostic snapshot of a light. World hides the 3 light
// attachment variants behind a single LightView so the engine staging layer
// does not need to know about PointLightAttachment / SpotLightAttachment /
// DirectionalLightAttachment or recompute position/direction from the world
// matrix.

import "core:math/linalg"

LightKind :: enum {
  POINT,
  DIRECTIONAL,
  SPOT,
}

LightView :: struct {
  kind:        LightKind,
  color:       [4]f32, // RGB + intensity
  position:    [3]f32,
  direction:   [3]f32, // normalised; defaulted to {0,-1,0} when the node has no orientation
  radius:      f32,
  angle_inner: f32,    // spot only
  angle_outer: f32,    // spot only
  cast_shadow: bool,
  enabled:     bool,
}

// light_view returns the snapshot the engine should upload. Returns ok=false
// when the node has no light attachment at all (the caller should treat that
// as "remove this light").
light_view :: proc(n: ^Node) -> (lv: LightView, ok: bool) {
  position := n.transform.world_matrix[3].xyz
  raw_dir := n.transform.world_matrix[2].xyz
  direction := [3]f32{0, -1, 0}
  if linalg.dot(raw_dir, raw_dir) >= 1e-6 {
    direction = linalg.normalize(raw_dir)
  }
  lv.position = position
  lv.direction = direction
  #partial switch att in n.attachment {
  case PointLightAttachment:
    lv.kind = .POINT
    lv.color = att.color
    lv.radius = att.radius
    lv.cast_shadow = att.cast_shadow
    lv.enabled = !att.disabled
    return lv, true
  case DirectionalLightAttachment:
    lv.kind = .DIRECTIONAL
    lv.color = att.color
    lv.radius = att.radius
    lv.cast_shadow = att.cast_shadow
    lv.enabled = !att.disabled
    return lv, true
  case SpotLightAttachment:
    lv.kind = .SPOT
    lv.color = att.color
    lv.radius = att.radius
    lv.angle_inner = att.angle_inner
    lv.angle_outer = att.angle_outer
    lv.cast_shadow = att.cast_shadow
    lv.enabled = !att.disabled
    return lv, true
  }
  return {}, false
}
