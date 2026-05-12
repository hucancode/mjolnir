package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

OBJ_FILES :: [3]string {
  "assets/nav_test.obj",
  "assets/floor_with_5_obstacles.obj",
  "assets/dungeon.obj",
}
OBJ_SCALES :: [3]f32{1.0, 1.0, 0.05}
OBJ_LABELS :: [3]string{"nav_test", "5 obstacles", "dungeon"}

display_node: world.NodeHandle
display_material: world.MaterialHandle
loaded_meshes: [3]world.MeshHandle
loaded_aabb: [3]struct{min, max: [3]f32}
current_index: int = -1

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "OBJ Loader")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true

  light := world.spawn(
    &engine.world,
    {10, 18, 10},
    world.create_directional_light_attachment({1, 0.97, 0.92, 3.0}, 10.0, false),
  ) or_else {}
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)

  display_material = world.create_material(
    &engine.world,
    type = .RANDOM_COLOR,
    base_color_factor = {0.7, 0.6, 0.5, 1},
  ) or_else {}

  files := OBJ_FILES
  scales := OBJ_SCALES
  for i in 0 ..< 3 {
    geom, ok := geometry.load_obj(files[i], scales[i])
    if !ok {
      log.errorf("failed to load %s", files[i])
      continue
    }
    log.infof(
      "%s: %d verts, %d tris, aabb %v..%v",
      files[i], len(geom.vertices), len(geom.indices) / 3, geom.aabb.min, geom.aabb.max,
    )
    loaded_aabb[i] = {geom.aabb.min, geom.aabb.max}
    mh, _ := world.create_mesh(&engine.world, geom)
    loaded_meshes[i] = mh
  }

  display_node = world.spawn(
    &engine.world,
    {0, 0, 0},
    world.MeshAttachment{handle = loaded_meshes[0], material = display_material, cast_shadow = true},
  ) or_else {}

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

  if n, ok := world.node(&engine.world, display_node); ok {
    att, _ := &n.attachment.(world.MeshAttachment)
    att.handle = loaded_meshes[index]
    neg := -center
    world.translate(&n.transform, neg.x, neg.y, neg.z)
    world.stage_node_data(&engine.world.staging, display_node)
  }

  cam_dist := radius * 1.8
  if cam, ok := cont.get(engine.world.cameras, engine.world.main_camera); ok {
    cam.projection = world.PerspectiveProjection {
      fov          = 1.2,
      aspect_ratio = f32(cam.extent[0]) / f32(cam.extent[1]),
      near         = max(0.1, cam_dist * 0.01),
      far          = cam_dist * 5.0,
    }
  }
  world.main_camera_look_at(
    &engine.world,
    {cam_dist, cam_dist * 0.7, cam_dist},
    {0, 0, 0},
  )
  world.stage_camera_data(&engine.world.staging, engine.world.main_camera)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
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
