// Wavefront OBJ import, shown solid or as a wireframe of its triangles.
package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

obj_files := [3][]u8{#load("assets/nav_test.obj"), #load("assets/floor_with_5_obstacles.obj"), #load("assets/dungeon.obj")}
OBJ_SCALES :: [3]f32{1.0, 1.0, 0.05}
OBJ_LABELS :: [3]string{"nav_test", "5 obstacles", "dungeon"}

Model :: struct {
  mesh:   render.MeshHandle,
  bounds: geometry.Aabb,
}

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  models:    [3]Model,
  material:  render.MaterialHandle,
  wire:      render.MaterialHandle,
  wireframe: bool,
  display:   world.NodeHandle,
  current:   int,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "OBJ Loader") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      update = update,
      render = draw,
    },
  )
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  app.material = render.material_create(&app.renderer, render.make_material(type = .RANDOM_COLOR, base_color_factor = {0.7, 0.6, 0.5, 1}))
  app.wire = render.material_create(&app.renderer, render.make_material(.WIREFRAME))

  scales := OBJ_SCALES
  labels := OBJ_LABELS
  for i in 0 ..< 3 {
    obj, ok := load_obj(obj_files[i], scales[i])
    if !ok {
      log.errorf("failed to load %s", labels[i])
      continue
    }
    geom := geometry.make_mesh_from_triangles(obj.positions, obj.indices)
    obj_mesh_destroy(&obj)
    bounds := geometry.aabb_from_vertices(geom.vertices)
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
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

show_model :: proc(app: ^App, index: int) {
  app.current = index
  model := app.models[index]
  center := (model.bounds.min + model.bounds.max) * 0.5
  radius := max(linalg.length(model.bounds.max - model.bounds.min) * 0.5, 1)

  attach_model(app)
  world.transform(&app.scene, app.display).position = -center

  cam_dist := radius
  cam := render.main_camera(&app.renderer)
  cam.projection, cam.near, cam.far = render.PerspectiveProjection{1.2}, max(0.1, cam_dist * 0.01), cam_dist * 5.0
  app.orbit = render.make_orbit({cam_dist, cam_dist * 0.7, cam_dist}, {0, 0, 0})
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

attach_model :: proc(app: ^App) {
  material := app.wire if app.wireframe else app.material
  look := render.MeshAttachment{mesh = app.models[app.current].mesh, material = material, no_shadow = app.wireframe}
  render.attach(&app.renderer, app.display, look)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "OBJ Loader", {20, 20, 260, 200}) {
    labels := OBJ_LABELS
    mu.label(ctx, fmt.tprintf("Current: %s", labels[app.current]))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for label, i in labels {
      if .SUBMIT in mu.button(ctx, label) && i != app.current do show_model(app, i)
    }
    if .CHANGE in mu.checkbox(ctx, "Wireframe", &app.wireframe) do attach_model(app)
  }
}
