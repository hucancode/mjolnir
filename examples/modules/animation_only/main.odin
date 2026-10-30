// Animation on its own: a procedural arm waved by a clip with its hand pulled to a circling target by IK, and a tail trailing a swaying root. The command line writes a filmstrip to artifacts/modules/animation_only/poses.svg; the web page animates it live.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mjolnir/animation"

BONES :: 6
STEP :: 1.0 / 60

Figure :: struct {
  rig:      animation.Rig,
  animator: animation.Animator,
  color:    string,
}

arm, tail: Figure
reach: animation.LayerHandle
t: f32

setup :: proc() -> bool {
  make_chain(&arm, "#ffd166") or_return
  make_chain(&tail, "#4ea8de") or_return
  add_wave_clip(&arm.rig)
  animation.play(&arm.animator, &arm.rig, "wave")
  reach = animation.layer_create(&arm.animator, &arm.rig, animation.IKParams{target = target(), pole = {3, 2, 0}, pole_weight = 1}, []u32{2, 3, 4, 5})
  animation.layer_create(&tail.animator, &tail.rig, animation.TailParams{stiffness = 0.25, damping = 0.4}, []u32{0, 1, 2, 3, 4, 5})
  return true
}

teardown :: proc() {
  for f in ([]^Figure{&arm, &tail}) {
    animation.destroy(&f.animator)
    animation.destroy(&f.rig)
  }
}

target :: proc() -> [3]f32 {
  return {2 + math.cos(t * 3), 3.5 + math.sin(t * 3), 0}
}

advance :: proc() {
  t += STEP
  if p, ok := animation.layer_params(&arm.animator, reach, animation.IKParams); ok do p.target = target()
  animation.animator_update(&arm.animator, &arm.rig, STEP)
  sway := linalg.matrix4_translate([3]f32{1.5 * math.sin(t * 4), 0, 0})
  animation.animator_update(&tail.animator, &tail.rig, STEP, sway)
}

make_chain :: proc(f: ^Figure, color: string) -> bool {
  parents: [BONES]i32
  inverse_bind: [BONES]matrix[4, 4]f32
  for i in 0 ..< BONES {
    parents[i] = i32(i) - 1
    inverse_bind[i] = linalg.matrix4_translate([3]f32{0, -f32(i), 0})
  }
  animation.skeleton_init(&f.rig.skeleton, parents[:], inverse_bind[:]) or_return
  f.color = color
  return animation.animator_init(&f.animator, &f.rig)
}

add_wave_clip :: proc(rig: ^animation.Rig) {
  clip: animation.Clip
  animation.clip_init(&clip, BONES, "wave")
  bend :: proc(angle: f32) -> quaternion128 {return linalg.quaternion_angle_axis(angle, [3]f32{0, 0, 1})}
  times := []f32{0, 0.5, 1}
  animation.clip_set_rotations(&clip, 1, times, {bend(0.4), bend(-0.4), bend(0.4)})
  animation.clip_set_rotations(&clip, 2, times, {bend(-0.3), bend(0.3), bend(-0.3)})
  append(&rig.clips, clip)
}

draw :: proc(b: ^strings.Builder, x: f32) {
  S :: 30
  for f, row in ([]^Figure{&arm, &tail}) {
    origin := [2]f32{x, 230 + f32(row) * 250}
    for bone in 1 ..< BONES {
      a := animation.bone_matrix(&f.animator, u32(bone - 1))[3].xyz
      c := animation.bone_matrix(&f.animator, u32(bone))[3].xyz
      fmt.sbprintfln(b, `<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="4" stroke-linecap="round"/>`, origin.x + a.x * S, origin.y - a.y * S, origin.x + c.x * S, origin.y - c.y * S, f.color)
    }
  }
  goal := target()
  fmt.sbprintfln(b, `<circle cx="%.1f" cy="%.1f" r="3" fill="#e76f51"/>`, x + goal.x * S, 230 - goal.y * S)
}
