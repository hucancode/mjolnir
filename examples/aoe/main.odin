// Area-of-effect query over static bodies.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/physics"
import "core:log"
import "core:math"

cube_mesh_handles: [dynamic]world.NodeHandle
cube_body_to_mesh: map[physics.BodyHandle]world.NodeHandle
effector_sphere: world.NodeHandle
effector_position: [3]f32
orbit_angle: f32 = 0.0
orbit_radius: f32 = 15.0
effect_radius: f32 = 10.0
cube_scale: f32 = 0.3
clicked_cube: world.NodeHandle

phys: physics.World

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  physics.init(&phys)
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "AOE Query") do return
  if !render.init(&app.renderer, "AOE Query", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  cube_body_to_mesh = make(map[physics.BodyHandle]world.NodeHandle)
  cube_mesh := app.renderer.builtin_meshes[.CUBE]
  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]
  cube_mat := app.renderer.builtin_materials[.CYAN]
  effector_mat := render.material_create(&app.renderer, render.make_material(emissive_value = 5.0))
  grid_size := 50
  spacing: f32 = 1.0
  log.infof("Spawning %dx%d grid of cubes...", grid_size, grid_size)
  for x in 0 ..< grid_size do for z in 0 ..< grid_size {
    world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
    world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
    pos := [3]f32{world_x, 0.5, world_z}
    half := 0.5 * cube_scale
    parent := world.spawn(&app.scene, pos) or_continue
    body_handle := physics.body_create(
      &phys,
      pos,
      collider = physics.BoxCollider{half_extents = {half, half, half}},
      user = world.Handle(parent),
    ) or_continue
    mh := world.spawn(&app.scene, parent = parent) or_continue
    render.attach(&app.renderer, render.SlotHandle(mh.index), render.MeshAttachment{mesh = cube_mesh, material = cube_mat, cast_shadow = false})
    world.scale(&app.scene, mh, half, half, half)
    append(&cube_mesh_handles, mh)
    cube_body_to_mesh[body_handle] = mh
  }
  effector_position = {0, 1, 0}
  effector_sphere = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(effector_sphere.index), render.MeshAttachment{mesh = sphere_mesh, material = effector_mat, cast_shadow = false})
  world.translate(&app.scene, effector_sphere, effector_position)
  world.scale(&app.scene, effector_sphere, 0.5)
  render.camera_look_at(render.main_camera(&app.renderer), {10, 30, 10}, {0, 0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  log.infof("AOE test setup complete: %d cubes", len(cube_mesh_handles))
  return true
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
  physics.shutdown(&phys)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  mouse_click: if input.mouse_pressed(&app.input, .LEFT) && !app.input.mouse_captured {
    ray, ok := render.cursor_ray(&app.renderer, app.input.cursor)
    if !ok do break mouse_click
    log.infof("Ray: origin=%v, direction=%v", ray.origin, ray.direction)
    hit := physics.raycast(&phys, ray)
    clicked_cube = {}
    if !hit.hit do break mouse_click
    if mh, ok := cube_body_to_mesh[hit.body]; ok do clicked_cube = mh
  }
  orbit_angle += dt * 0.5
  effector_position = {math.cos(orbit_angle) * orbit_radius, 1.0, math.sin(orbit_angle) * orbit_radius}
  world.translate(&app.scene, effector_sphere, effector_position)
  for h in cube_mesh_handles do world.scale(&app.scene, h, cube_scale)
  affected: [dynamic]physics.BodyHandle
  defer delete(affected)
  physics.overlap(&phys, physics.SphereCollider{radius = effect_radius}, effector_position, 1, &affected)
  for bh in affected do if mh, ok := cube_body_to_mesh[bh]; ok do world.scale(&app.scene, mh, 0.1)
  world.scale(&app.scene, clicked_cube, cube_scale * 3.0)
  physics.step(&phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
