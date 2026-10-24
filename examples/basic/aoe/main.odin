// Area-of-effect query over static bodies.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "mjolnir/physics"
import "core:log"
import "core:math"
import "core:math/linalg"

GRID_SIZE :: 50
GRID_SPACING :: f32(1.0)
CUBE_HALF_EXTENT :: f32(0.15)
AFFECTED_HALF_EXTENT :: f32(0.05)
CLICKED_HALF_EXTENT :: f32(0.45)
EFFECT_RADIUS :: f32(10.0)
EFFECTOR_ORBIT_RADIUS :: f32(15.0)
EFFECTOR_ORBIT_SPEED :: f32(0.5)

App :: struct {
  platform:       platform.Platform,
  scene:          world.World,
  renderer:       render.Renderer,
  input:          input.State,
  orbit:          render.Orbit,
  phys:           physics.World,
  effector:       world.NodeHandle,
  effector_angle: f32,
  affected:       [dynamic]physics.BodyHandle,
  clicked:        physics.BodyHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !physics.init(&app.phys) do return
  if !platform.init(&app.platform, 800, 600, "AOE Query") do return
  if !render.init(&app.renderer, app.platform.window) do return
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
  cube := render.primitive(&app.renderer, .CUBE, .CYAN, cast_shadow = false)
  for x in 0 ..< GRID_SIZE do for z in 0 ..< GRID_SIZE {
    position := [3]f32{(f32(x) - GRID_SIZE * 0.5) * GRID_SPACING, 0.5, (f32(z) - GRID_SIZE * 0.5) * GRID_SPACING}
    node := world.spawn(&app.scene, position) or_continue
    render.attach(&app.renderer, render.SlotHandle(node.index), cube)
    world.scale(&app.scene, node, CUBE_HALF_EXTENT)
    physics.body_create(&app.phys, position, collider = physics.BoxCollider{half_extents = CUBE_HALF_EXTENT}, user = world.Handle(node))
  }
  effector_material := render.material_create(&app.renderer, render.make_material(emissive_value = 5.0))
  app.effector = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(app.effector.index), render.primitive(&app.renderer, .SPHERE, effector_material, cast_shadow = false))
  world.scale(&app.scene, app.effector, 0.5)
  app.orbit = render.make_orbit({10, 30, 10}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  log.infof("AOE test setup complete: %d cubes", GRID_SIZE * GRID_SIZE)
  return .READY
}

shutdown :: proc(app: ^App) {
  delete(app.affected)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  physics.shutdown(&app.phys)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

set_cube_half_extent :: proc(app: ^App, body: physics.BodyHandle, half_extent: f32) {
  if b, ok := physics.body(&app.phys, body); ok do world.scale(&app.scene, world.NodeHandle(b.user), half_extent)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  render.orbit_drag(&app.orbit, &app.input)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  if input.mouse_pressed(&app.input, .LEFT) && !app.input.mouse_captured {
    set_cube_half_extent(app, app.clicked, CUBE_HALF_EXTENT)
    app.clicked = {}
    if ray, ok := render.cursor_ray(&app.renderer, app.input.cursor); ok {
      if hit := physics.raycast(&app.phys, ray); hit.hit do app.clicked = hit.body
    }
  }

  app.effector_angle += dt * EFFECTOR_ORBIT_SPEED
  effector_position := [3]f32{math.cos(app.effector_angle), 0, math.sin(app.effector_angle)} * EFFECTOR_ORBIT_RADIUS + {0, 1, 0}
  world.translate(&app.scene, app.effector, effector_position)

  for body in app.affected do set_cube_half_extent(app, body, CUBE_HALF_EXTENT)
  physics.overlap(&app.phys, physics.SphereCollider{radius = EFFECT_RADIUS}, effector_position, linalg.QUATERNIONF32_IDENTITY, &app.affected)
  for body in app.affected do set_cube_half_extent(app, body, AFFECTED_HALF_EXTENT)
  set_cube_half_extent(app, app.clicked, CLICKED_HALF_EXTENT)

  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}
