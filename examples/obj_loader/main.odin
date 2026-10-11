package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
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

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1000, 700, "OBJ Loader") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "OBJ Loader", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = render.orbit_controller()

  light := world.spawn(&app.scene, {10, 18, 10})
  render.attach(&app.renderer, light.index, render.directional_light_attachment({1, 0.97, 0.92, 3.0}, 10.0, false))
  world.rotate(&app.scene, light, 1.5707963, [3]f32{1, 0, 0})

  display_material = render.create_material(&app.renderer, type = .RANDOM_COLOR, base_color_factor = {0.7, 0.6, 0.5, 1})

  files := OBJ_FILES
  scales := OBJ_SCALES
  for i in 0 ..< 3 {
    obj, ok := load_obj(files[i], scales[i])
    if !ok {
      log.errorf("failed to load %s", files[i])
      continue
    }
    geom := mesh.from_triangles(obj.positions, obj.indices)
    obj_mesh_destroy(&obj)
    aabb := mesh.aabb_from_vertices(geom.vertices)
    log.infof("%s: %d verts, %d tris, aabb %v..%v", files[i], len(geom.vertices), len(geom.indices) / 3, aabb.min, aabb.max)
    loaded_aabb[i] = {aabb.min, aabb.max}
    loaded_meshes[i] = render.create_mesh(&app.renderer, geom)
  }

  display_node = world.spawn(&app.scene)
  render.attach(&app.renderer, display_node.index, render.MeshAttachment{handle = loaded_meshes[0], material = display_material, cast_shadow = true})
  swap_model(app, 0)

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  render.update(&app.renderer, dt)
}

swap_model :: proc(app: ^App, index: int) {
  if index == current_index do return
  current_index = index

  aabb := loaded_aabb[index]
  center := (aabb.min + aabb.max) * 0.5
  extents := aabb.max - aabb.min
  radius := linalg.length(extents) * 0.5
  if radius < 0.001 do radius = 1

  if a, ok := render.attachment(&app.renderer, display_node.index, render.MeshAttachment); ok {
    a.handle = loaded_meshes[index]
    render.attach(&app.renderer, display_node.index, a)
  }
  world.translate(&app.scene, display_node, -center)

  cam_dist := radius * 1.8
  cam := render.main_camera(&app.renderer)
  render.camera_set_perspective(cam, 1.2, max(0.1, cam_dist * 0.01), cam_dist * 5.0)
  render.camera_look_at(cam, {cam_dist, cam_dist * 0.7, cam_dist}, {0, 0, 0})
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "OBJ Loader", {720, 20, 260, 200}, {.NO_CLOSE}) {
    labels := OBJ_LABELS
    mu.label(ctx, fmt.tprintf("Current: %s", labels[current_index] if current_index >= 0 else "<none>"))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for label, i in labels {
      if .SUBMIT in mu.button(ctx, label) do swap_model(app, i)
    }
  }
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
