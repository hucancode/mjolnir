// Joints: a pendulum, a hinged door with limits and a rope of ball joints. Click a body to push it.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "mjolnir/physics"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

PENDULUM_ANCHOR :: [3]f32{-5, 6, 0}
BOB_RADIUS :: f32(0.5)
DOOR_HINGE :: [3]f32{-0.8, 0, 0}
DOOR_HALF_EXTENTS :: [3]f32{0.8, 1.2, 0.06}
DOOR_LIMIT :: f32(math.PI * 0.5)
ROPE_ANCHOR :: [3]f32{3, 6, 0}
ROPE_LINKS :: 10
LINK_HALF_EXTENTS :: [3]f32{0.25, 0.07, 0.07}
PUSH_IMPULSE :: f32(6)

Piece :: struct {
  body:     physics.BodyHandle,
  position: [3]f32,
  rotation: quaternion128,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  phys:     physics.World,
  debug:    debugui.Context,
  pieces:   [dynamic]Piece,
  bob:      physics.BodyHandle,
  links:    [ROPE_LINKS]physics.BodyHandle,
  wind:     bool,
  strength: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.strength = 4
  if !physics.init(&app.phys) do return
  if !platform.init(&app.platform, 1280, 720, "Joints") do return
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

shutdown :: proc(app: ^App) {
  delete(app.pieces)
  debugui.shutdown(&app.debug)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  physics.shutdown(&app.phys)
  free(app)
}

spawn_piece :: proc(app: ^App, position: [3]f32, collider: physics.Collider, look: render.MeshAttachment, size: [3]f32, mass: f32) -> physics.BodyHandle {
  node := world.spawn(&app.scene, position)
  mjolnir.spawn_mesh(&app.scene, &app.renderer, look, scale = size, parent = node)
  body := physics.body_create(&app.phys, position, collider = collider, mass = mass, user = world.Handle(node))
  if mass > 0 do append(&app.pieces, Piece{body, position, linalg.QUATERNIONF32_IDENTITY})
  return body
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 4, 10}, {0, 2.5, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  spawn_piece(app, {0, -0.5, 0}, physics.BoxCollider{half_extents = {9, 0.5, 4}}, render.primitive(&app.renderer, .CUBE, .GRAY), {9, 0.5, 4}, 0)
  spawn_piece(app, PENDULUM_ANCHOR, physics.BoxCollider{half_extents = 0.15}, render.primitive(&app.renderer, .CUBE, .WHITE), 0.15, 0)
  spawn_piece(app, ROPE_ANCHOR, physics.BoxCollider{half_extents = 0.15}, render.primitive(&app.renderer, .CUBE, .WHITE), 0.15, 0)
  spawn_piece(app, DOOR_HINGE + {-0.1, 1.3, 0}, physics.BoxCollider{half_extents = {0.08, 1.3, 0.08}}, render.primitive(&app.renderer, .CUBE, .WHITE), {0.08, 1.3, 0.08}, 0)

  app.bob = spawn_piece(app, PENDULUM_ANCHOR + {2.5, -2.5, 0}, physics.SphereCollider{radius = BOB_RADIUS}, render.primitive(&app.renderer, .SPHERE, .MAGENTA), BOB_RADIUS, 5)
  physics.joint_create(&app.phys, app.bob, {}, physics.BallJoint{anchor = PENDULUM_ANCHOR})
  physics.set_velocity(&app.phys, app.bob, {0, 0, 3})

  door := spawn_piece(app, DOOR_HINGE + {DOOR_HALF_EXTENTS.x, DOOR_HALF_EXTENTS.y + 0.05, 0}, physics.BoxCollider{half_extents = DOOR_HALF_EXTENTS}, render.primitive(&app.renderer, .CUBE, .YELLOW), DOOR_HALF_EXTENTS, 10)
  physics.joint_create(&app.phys, door, {}, physics.HingeJoint{anchor = DOOR_HINGE + {0, 1.25, 0}, axis = {0, 1, 0}, lower = -DOOR_LIMIT, upper = DOOR_LIMIT})
  physics.set_angular_velocity(&app.phys, door, {0, 4, 0})

  link_look := render.primitive(&app.renderer, .CUBE, .CYAN)
  previous: physics.BodyHandle
  for &link, i in app.links {
    start := ROPE_ANCHOR + {f32(i) * LINK_HALF_EXTENTS.x * 2, 0, 0}
    link = spawn_piece(app, start + {LINK_HALF_EXTENTS.x, 0, 0}, physics.BoxCollider{half_extents = LINK_HALF_EXTENTS}, link_look, LINK_HALF_EXTENTS, 1)
    physics.joint_create(&app.phys, link, previous, physics.BallJoint{anchor = start})
    previous = link
  }
  return .READY
}

reset :: proc(app: ^App) {
  for p in app.pieces {
    physics.set_pose(&app.phys, p.body, p.position, p.rotation)
    physics.set_velocity(&app.phys, p.body, 0)
    physics.set_angular_velocity(&app.phys, p.body, 0)
  }
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input, rotate_with = {.RIGHT})

  if input.mouse_pressed(&app.input, .LEFT) && !app.input.mouse_captured {
    if ray, ok := render.cursor_ray(&app.renderer, app.input.cursor); ok {
      hit := physics.raycast(&app.phys, ray)
      if hit.hit {
        if b := physics.body(&app.phys, hit.body); b.inv_mass > 0 do physics.apply_impulse_at(&app.phys, hit.body, ray.direction * PUSH_IMPULSE / b.inv_mass, hit.point)
      }
    }
  }
  if app.wind do for p in app.pieces {
    physics.apply_force(&app.phys, p.body, {0, 0, -app.strength / physics.body(&app.phys, p.body).inv_mass})
  }

  physics.step(&app.phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  render.debug_segment(&app.renderer, PENDULUM_ANCHOR, physics.body(&app.phys, app.bob).position, render.COLOR_RGB[.WHITE])
  mjolnir.update(&app.scene, &app.renderer, dt)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Joints", {20, 20, 220, 180}, {}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Left click: push")
    mu.label(ctx, "Right drag: orbit")
    mu.checkbox(ctx, "Wind", &app.wind)
    mu.slider(ctx, &app.strength, 0, 20)
    if .SUBMIT in mu.button(ctx, "Reset") do reset(app)
  }
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
