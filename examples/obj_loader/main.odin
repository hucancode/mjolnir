// Wavefront OBJ import.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/geometry"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

obj_files := [3][]u8{#load("../../assets/nav_test.obj"), #load("../../assets/floor_with_5_obstacles.obj"), #load("../../assets/dungeon.obj")}
OBJ_SCALES :: [3]f32{1.0, 1.0, 0.05}
OBJ_LABELS :: [3]string{"nav_test", "5 obstacles", "dungeon"}

Model :: struct {
  mesh:   render.MeshHandle,
  bounds: geometry.Aabb,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  models:   [3]Model,
  material: render.MaterialHandle,
  display:  world.NodeHandle,
  current:  int,
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  light := world.spawn(&app.scene, {10, 18, 10})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92}, 3.0, 10.0, false)))
  world.rotate(&app.scene, light, -math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)

  app.material = render.material_create(&app.renderer, render.make_material(type = .RANDOM_COLOR, base_color_factor = {0.7, 0.6, 0.5, 1}))

  scales := OBJ_SCALES
  labels := OBJ_LABELS
  for i in 0 ..< 3 {
    obj, ok := load_obj(obj_files[i], scales[i])
    if !ok {
      log.errorf("failed to load %s", labels[i])
      continue
    }
    geom := render.make_geometry_from_triangles(obj.positions, obj.indices)
    obj_mesh_destroy(&obj)
    bounds := render.aabb_from_vertices(geom.vertices)
    log.infof("%s: %d verts, %d tris, aabb %v..%v", labels[i], len(geom.vertices), len(geom.indices) / 3, bounds.min, bounds.max)
    app.models[i] = {mesh = render.mesh_create(&app.renderer, geom), bounds = bounds}
  }

  app.display = world.spawn(&app.scene)
  show_model(app, 0)
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
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
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

show_model :: proc(app: ^App, index: int) {
  app.current = index
  model := app.models[index]
  center := (model.bounds.min + model.bounds.max) * 0.5
  radius := max(linalg.length(model.bounds.max - model.bounds.min) * 0.5, 1)

  render.attach(&app.renderer, render.SlotHandle(app.display.index), render.MeshAttachment{mesh = model.mesh, material = app.material, cast_shadow = true})
  world.translate(&app.scene, app.display, -center)

  cam_dist := radius * 1.8
  cam := render.main_camera(&app.renderer)
  render.camera_set_perspective(cam, 1.2, max(0.1, cam_dist * 0.01), cam_dist * 5.0)
  render.camera_look_at(cam, {cam_dist, cam_dist * 0.7, cam_dist}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(cam)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "OBJ Loader", {720, 20, 260, 200}, {.NO_CLOSE}) {
    labels := OBJ_LABELS
    mu.label(ctx, fmt.tprintf("Current: %s", labels[app.current]))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for label, i in labels {
      if .SUBMIT in mu.button(ctx, label) && i != app.current do show_model(app, i)
    }
  }
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
