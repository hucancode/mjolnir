package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/render/mesh"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

OBJ_FILES :: [3]string{"assets/nav_test.obj", "assets/floor_with_5_obstacles.obj", "assets/dungeon.obj"}
OBJ_SCALES :: [3]f32{1.0, 1.0, 0.05}
OBJ_LABELS :: [3]string{"nav_test", "5 obstacles", "dungeon"}

display_node: world.NodeHandle
display_material: render.MaterialHandle
loaded_meshes: [3]render.MeshHandle
loaded_aabb: [3]struct{min, max: [3]f32}
current_index: int = -1

main :: proc() {
  mjolnir.run_app({
    title = "OBJ Loader", width = 1000, height = 700,
    debug_ui = true, setup = setup, update = update, pre_render = debug_ui,
  })
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

setup :: proc(engine: ^mjolnir.Engine) {
  light := mjolnir.spawn(engine, {10, 18, 10}, render.directional_light_attachment({1, 0.97, 0.92, 3.0}, 10.0, false))
  world.rotate(&engine.world, light, 1.5707963, [3]f32{1, 0, 0})

  display_material = render.create_material(&engine.render, type = .RANDOM_COLOR, base_color_factor = {0.7, 0.6, 0.5, 1})

  files := OBJ_FILES
  scales := OBJ_SCALES
  for i in 0 ..< 3 {
    obj, ok := mesh.load_obj(files[i], scales[i])
    if !ok {
      log.errorf("failed to load %s", files[i])
      continue
    }
    geom := mesh.from_triangles(obj.positions, obj.indices)
    mesh.obj_mesh_destroy(&obj)
    aabb := mesh.aabb_from_vertices(geom.vertices)
    log.infof("%s: %d verts, %d tris, aabb %v..%v", files[i], len(geom.vertices), len(geom.indices) / 3, aabb.min, aabb.max)
    loaded_aabb[i] = {aabb.min, aabb.max}
    loaded_meshes[i] = render.create_mesh(&engine.render, geom)
  }

  display_node = mjolnir.spawn_mesh(engine, loaded_meshes[0], display_material)
  swap_model(engine, 0)
}

swap_model :: proc(engine: ^mjolnir.Engine, index: int) {
  if index == current_index do return
  current_index = index

  aabb := loaded_aabb[index]
  center := (aabb.min + aabb.max) * 0.5
  extents := aabb.max - aabb.min
  radius := linalg.length(extents) * 0.5
  if radius < 0.001 do radius = 1

  if a, ok := render.attachment(&engine.render, display_node.index, render.MeshAttachment); ok {
    a.handle = loaded_meshes[index]
    render.mark_slot_dirty(&engine.render, display_node.index)
  }
  world.translate(&engine.world, display_node, -center)

  cam_dist := radius * 1.8
  cam := render.main_camera(&engine.render)
  render.camera_set_perspective(cam, 1.2, max(0.1, cam_dist * 0.01), cam_dist * 5.0)
  render.camera_look_at(cam, {cam_dist, cam_dist * 0.7, cam_dist}, {0, 0, 0})
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "OBJ Loader", {720, 20, 260, 200}, {.NO_CLOSE}) {
    labels := OBJ_LABELS
    mu.label(ctx, fmt.tprintf("Current: %s", labels[current_index] if current_index >= 0 else "<none>"))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for label, i in labels {
      if .SUBMIT in mu.button(ctx, label) do swap_model(engine, i)
    }
  }
}
