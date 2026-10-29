// Animation on its own: a procedural arm waved by a clip with its hand pulled to a circling target by IK, and a tail trailing a swaying root. Writes artifacts/modules/animation_only/poses.svg.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "mjolnir/animation"

OUT :: "artifacts/modules/animation_only/"
BONES :: 6
FRAMES :: 12
STEP :: 1.0 / 60

Figure :: struct {
  rig:      animation.Rig,
  animator: animation.Animator,
  color:    string,
}

main :: proc() {
  arm, tail: Figure
  if !make_chain(&arm, "#ffd166") || !make_chain(&tail, "#4ea8de") do return
  defer for f in ([]^Figure{&arm, &tail}) {
    animation.animator_destroy(&f.animator)
    animation.rig_destroy(&f.rig)
  }
  add_wave_clip(&arm.rig)
  animation.play(&arm.animator, &arm.rig, "wave")
  hand := []u32{2, 3, 4, 5}
  reach := animation.layer_create(&arm.animator, &arm.rig, animation.IKParams{target = {2, 3, 0}, pole = {3, 2, 0}, pole_weight = 1}, hand)
  animation.layer_create(&tail.animator, &tail.rig, animation.TailParams{stiffness = 0.25, damping = 0.4}, []u32{0, 1, 2, 3, 4, 5})

  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d 500" style="background:#14161f">`, FRAMES * 120)
  t := f32(0)
  for frame in 0 ..< FRAMES {
    for _ in 0 ..< 10 {
      t += STEP
      target := [3]f32{2 + math.cos(t * 3), 3.5 + math.sin(t * 3), 0}
      if p, ok := animation.layer_params(&arm.animator, reach, animation.IKParams); ok do p.target = target
      animation.animator_update(&arm.animator, &arm.rig, STEP)
      sway := linalg.matrix4_translate([3]f32{1.5 * math.sin(t * 4), 0, 0})
      animation.animator_update(&tail.animator, &tail.rig, STEP, sway)
    }
    x := f32(frame) * 120 + 60
    draw(&b, &arm, {x, 230})
    draw(&b, &tail, {x, 480})
    target := [3]f32{2 + math.cos(t * 3), 3.5 + math.sin(t * 3), 0}
    fmt.sbprintfln(&b, `<circle cx="%.1f" cy="%.1f" r="3" fill="#e76f51"/>`, x + target.x * 30, 230 - target.y * 30)
  }
  fmt.sbprintln(&b, "</svg>")
  os.make_directory_all(OUT)
  _ = os.write_entire_file(OUT + "poses.svg", strings.to_string(b))
  end := animation.bone_matrix(&arm.animator, 5)[3].xyz
  target := [3]f32{2 + math.cos(t * 3), 3.5 + math.sin(t * 3), 0}
  fmt.printfln("%d frames of %d bones; the hand ends %.2f from its target", FRAMES, BONES, linalg.distance(end, target))
  fmt.printfln("wrote %sposes.svg", OUT)
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

draw :: proc(b: ^strings.Builder, f: ^Figure, origin: [2]f32) {
  S :: 30
  for bone in 1 ..< BONES {
    a := animation.bone_matrix(&f.animator, u32(bone - 1))[3].xyz
    c := animation.bone_matrix(&f.animator, u32(bone))[3].xyz
    fmt.sbprintfln(b, `<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="4" stroke-linecap="round"/>`, origin.x + a.x * S, origin.y - a.y * S, origin.x + c.x * S, origin.y - c.y * S, f.color)
  }
}
