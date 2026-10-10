package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:math"

scene: mjolnir.GltfScene

main :: proc() {
  defer mjolnir.gltf_scene_destroy(&scene)
  mjolnir.run_app({
    title  = "GLTF Static",
    setup  = proc(engine: ^mjolnir.Engine) {
      render.main_camera_look_at(&engine.render, {5, 6, 5}, {0, 5, 0})
      scene = mjolnir.load_gltf(engine, "assets/Duck.glb")
      mjolnir.spawn(engine, attachment = render.directional_light_attachment())
    },
    update = proc(engine: ^mjolnir.Engine, dt: f32) {
      rot := dt * math.PI * 0.5
      for h in scene.roots do world.rotate_by(&engine.world, h, rot)
      world.update(&engine.world)
      for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
      for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
    },
  })
}
