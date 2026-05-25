package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

OBJ_FILES :: [3]string{"assets/nav_test.obj", "assets/floor_with_5_obstacles.obj", "assets/dungeon.obj"}
OBJ_SCALES :: [3]f32{1.0, 1.0, 0.05}
OBJ_LABELS :: [3]string{"nav_test", "5 obstacles", "dungeon"}

display_node: world.NodeHandle
display_material: world.MaterialHandle
loaded_meshes: [3]world.MeshHandle
loaded_aabb: [3]struct{min, max: [3]f32}
current_index: int = -1

main :: proc() {
  mjolnir.run_app({
    title = "OBJ Loader", width = 1000, height = 700,
    debug_ui = true, setup = setup, pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  light := world.spawn_light_directional(&engine.world, {10, 18, 10}, {1, 0.97, 0.92, 3.0}, 10.0, false)
  world.rotate(&engine.world, light, 1.5707963, [3]f32{1, 0, 0})

  display_material = world.create_material(&engine.world, type = .RANDOM_COLOR, base_color_factor = {0.7, 0.6, 0.5, 1})

  files := OBJ_FILES
  scales := OBJ_SCALES
  for i in 0 ..< 3 {
    geom, ok := geometry.load_obj(files[i], scales[i])
    if !ok {
      log.errorf("failed to load %s", files[i])
      continue
    }
    log.infof("%s: %d verts, %d tris, aabb %v..%v", files[i], len(geom.vertices), len(geom.indices) / 3, geom.aabb.min, geom.aabb.max)
    loaded_aabb[i] = {geom.aabb.min, geom.aabb.max}
    loaded_meshes[i] = world.create_mesh(&engine.world, geom)
  }

  display_node = world.spawn_mesh(&engine.world, loaded_meshes[0], display_material)
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

  world.set_mesh_handle(&engine.world, display_node, loaded_meshes[index])
  world.translate(&engine.world, display_node, -center)

  cam_dist := radius * 1.8
  world.main_camera_set_perspective(&engine.world,
    fov  = 1.2,
    from = {cam_dist, cam_dist * 0.7, cam_dist},
    to   = {0, 0, 0},
    near = max(0.1, cam_dist * 0.01),
    far  = cam_dist * 5.0,
  )
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
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
