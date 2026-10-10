package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:math"

scene: mjolnir.GltfScene
// one animator per skinned node of the scene
animators: [dynamic]anim.Animator

main :: proc() {
  defer mjolnir.gltf_scene_destroy(&scene)
  mjolnir.run_app({
    title  = "GLTF Animation",
    setup  = setup,
    update = update,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {1.5, 1.5, 1.5}, {0, 1, 0})
  scene = mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
  for s in scene.skinned {
    rig := &scene.rigs[s.rig]
    a: anim.Animator
    anim.animator_init(&a, rig)
    anim.play(&a, rig, "Anim_0")
    append(&animators, a)
  }
  mjolnir.spawn(engine, attachment = render.directional_light_attachment())
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  rot := dt * math.PI * 0.05
  for h in scene.roots do world.rotate_by(&engine.world, h, rot)
  for s, i in scene.skinned do anim.animator_update(&animators[i], &scene.rigs[s.rig], dt)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
  for s, i in scene.skinned do render.stage_bones(&engine.render, s.node.index, animators[i].palette)
}
