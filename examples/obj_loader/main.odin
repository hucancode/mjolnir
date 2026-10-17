// Wavefront OBJ import.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

obj_files := [3][]u8{#load("../../assets/nav_test.obj"), #load("../../assets/floor_with_5_obstacles.obj"), #load("../../assets/dungeon.obj")}
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
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "OBJ Loader") do return
  if !render.init(&app.renderer, "OBJ Loader", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  light := world.spawn(&app.scene, {10, 18, 10})
  render.attach(&app.renderer, light.index, render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92, 3.0}, 10.0, false)))
  world.rotate(&app.scene, light, 1.5707963, [3]f32{1, 0, 0})

  display_material = render.material_create(&app.renderer, type = .RANDOM_COLOR, base_color_factor = {0.7, 0.6, 0.5, 1})

  scales := OBJ_SCALES
  labels := OBJ_LABELS
  for i in 0 ..< 3 {
    obj, ok := load_obj(obj_files[i], scales[i])
    if !ok {
      log.errorf("failed to load %s", labels[i])
      continue
    }
    geom := render.from_triangles(obj.positions, obj.indices)
    obj_mesh_destroy(&obj)
    aabb := render.aabb_from_vertices(geom.vertices)
    log.infof("%s: %d verts, %d tris, aabb %v..%v", labels[i], len(geom.vertices), len(geom.indices) / 3, aabb.min, aabb.max)
    loaded_aabb[i] = {aabb.min, aabb.max}
    loaded_meshes[i] = render.mesh_create(&app.renderer, geom)
  }

  display_node = world.spawn(&app.scene)
  render.attach(&app.renderer, display_node.index, render.MeshAttachment{handle = loaded_meshes[0], material = display_material, cast_shadow = true})
  swap_model(app, 0)
  return true
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.destroy(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
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
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(cam)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "OBJ Loader", {720, 20, 260, 200}, {.NO_CLOSE}) {
    labels := OBJ_LABELS
    mu.label(ctx, fmt.tprintf("Current: %s", labels[current_index] if current_index >= 0 else "<none>"))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for label, i in labels {
      if .SUBMIT in mu.button(ctx, label) do swap_model(app, i)
    }
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
