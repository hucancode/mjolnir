// Collision scenarios to run, pause and step through one physics tick at a time.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/physics"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

STEP_DT :: f32(1.0 / 60.0)
MAX_STEPS_PER_FRAME :: 4
GRAVITY :: [3]f32{0, -9.81, 0}

Scenario :: enum {
  SPHERE_DROP,
  BOX_FLAT,
  BOX_ON_EDGE,
  CYLINDERS,
  HEAD_ON,
  BOUNCE,
  SLOPE,
  STACK,
  BULLET,
}

EXPECTED := [Scenario]string {
  .SPHERE_DROP = "The sphere lands with 1 contact point, stops and falls asleep.",
  .BOX_FLAT    = "The box lands flat with 4 contact points and does not rotate.",
  .BOX_ON_EDGE = "The box lands on a corner, tips over and settles flat with 4 points.",
  .CYLINDERS   = "Upright: 4 cap points. Lying: 2 points along its side. Both fall asleep.",
  .HEAD_ON     = "No gravity, restitution 1. Equal spheres swap velocities; momentum stays 0.",
  .BOUNCE      = "Restitution 0 / 0.5 / 0.9 from left to right: higher bounces last longer.",
  .SLOPE       = "Friction 1 box sticks to the 25 degree slope, friction 0.05 box slides off.",
  .STACK       = "Five boxes stay stacked upright and fall asleep together.",
  .BULLET      = "A 150 m/s pellet bounces off a 10 cm wall instead of tunneling through.",
}

Tracked :: struct {
  name:     string,
  handle:   physics.BodyHandle,
  collider: physics.Collider,
}

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  phys:      physics.World,
  scenario:  Scenario,
  bodies:    [dynamic]Tracked,
  steps:     int,
  playing:   bool,
  speed:     f32,
  banked:    f32,
  rewind_to: Maybe(int),
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Collision") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  if !physics.init(&app.phys, thread_count = 1) do return
  app.phys.rate = 0
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
  delete(app.bodies)
  physics.shutdown(&app.phys)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  render.setup(&app.renderer)
  app.orbit = render.make_orbit({9, 7, 12}, {0, 1, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.speed = 1
  load(app, .SPHERE_DROP)
  return .READY
}

load :: proc(app: ^App, scenario: Scenario) {
  physics.teardown(&app.phys)
  world.teardown(&app.scene)
  render.teardown(&app.renderer)
  clear(&app.bodies)
  app.scenario = scenario
  app.steps = 0
  app.banked = 0
  app.phys.gravity = GRAVITY
  ground := add(app, "ground", physics.BoxCollider{half_extents = {10, 0.5, 10}}, {0, -0.5, 0})
  physics.body_params(&app.phys, ground).restitution = 0
  switch scenario {
  case .SPHERE_DROP:
    add(app, "sphere", physics.SphereCollider{radius = 0.5}, {0, 3, 0}, 1, .MAGENTA)
  case .BOX_FLAT:
    add(app, "box", physics.BoxCollider{half_extents = 0.5}, {0, 3, 0}, 1, .RED)
  case .BOX_ON_EDGE:
    add(app, "box", physics.BoxCollider{half_extents = 0.5}, {0, 3, 0}, 1, .RED, turn(40, {1, 0, 1}))
  case .CYLINDERS:
    add(app, "upright", physics.CylinderCollider{radius = 0.5, half_height = 0.75}, {-1.5, 2, 0}, 1, .CYAN)
    add(app, "lying", physics.CylinderCollider{radius = 0.5, half_height = 0.75}, {1.5, 2, 0}, 1, .ORANGE, turn(90, {1, 0, 0}))
  case .HEAD_ON:
    app.phys.gravity = {}
    left := add(app, "left", physics.SphereCollider{radius = 0.5}, {-3, 2, 0}, 1, .MAGENTA, velocity = {4, 0, 0})
    right := add(app, "right", physics.SphereCollider{radius = 0.5}, {3, 2, 0}, 1, .CYAN, velocity = {-4, 0, 0})
    physics.body_params(&app.phys, left).restitution = 1
    physics.body_params(&app.phys, right).restitution = 1
  case .BOUNCE:
    names := [3]string{"e = 0", "e = 0.5", "e = 0.9"}
    for restitution, i in ([3]f32{0, 0.5, 0.9}) {
      ball := add(app, names[i], physics.SphereCollider{radius = 0.4}, {f32(i - 1) * 1.5, 4, 0}, 1, .YELLOW)
      physics.body_params(&app.phys, ball).restitution = restitution
    }
  case .SLOPE:
    slope := turn(25, {0, 0, 1})
    add(app, "slope", physics.BoxCollider{half_extents = {4, 0.25, 2}}, {0, 2, 0}, 0, .GRAY, slope)
    up := linalg.quaternion_mul_vector3(slope, [3]f32{0, 1, 0})
    rough := add(app, "rough", physics.BoxCollider{half_extents = 0.4}, [3]f32{0, 2, -1} + up * 0.66, 1, .GREEN, slope)
    slick := add(app, "slick", physics.BoxCollider{half_extents = 0.4}, [3]f32{0, 2, 1} + up * 0.66, 1, .BLUE, slope)
    physics.body_params(&app.phys, rough).friction = 1
    physics.body_params(&app.phys, slick).friction = 0.05
  case .STACK:
    names := [5]string{"box 0", "box 1", "box 2", "box 3", "box 4"}
    for i in 0 ..< 5 {
      add(app, names[i], physics.BoxCollider{half_extents = 0.5}, {0, 0.5 + f32(i) * 1.02, 0}, 1, .RED if i % 2 == 0 else .ORANGE)
    }
  case .BULLET:
    app.phys.gravity = {}
    add(app, "wall", physics.BoxCollider{half_extents = {0.05, 2, 2}}, {3, 2, 0}, 0, .GRAY)
    add(app, "pellet", physics.SphereCollider{radius = 0.1}, {-4, 2, 0}, 0.1, .YELLOW, velocity = {150, 0, 0})
  }
}

add :: proc(
  app: ^App,
  name: string,
  collider: physics.Collider,
  position: [3]f32,
  mass: f32 = 0,
  color := render.Color.GRAY,
  rotation := linalg.QUATERNIONF32_IDENTITY,
  velocity := [3]f32{},
) -> physics.BodyHandle {
  node := world.spawn(&app.scene, position)
  world.rotate(&app.scene, node, rotation)
  mesh, scale := look(collider)
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, mesh, color), scale = scale, parent = node)
  handle := physics.body_create(&app.phys, position, rotation, collider, mass, user = world.Handle(node))
  if velocity != {} do physics.set_velocity(&app.phys, handle, velocity)
  append(&app.bodies, Tracked{name, handle, collider})
  return handle
}

turn :: proc(degrees: f32, axis: [3]f32) -> quaternion128 {
  return linalg.quaternion_angle_axis_f32(degrees * math.RAD_PER_DEG, linalg.normalize(axis))
}

look :: proc(collider: physics.Collider) -> (render.Primitive, [3]f32) {
  switch c in collider {
  case physics.SphereCollider:   return .SPHERE, c.radius
  case physics.BoxCollider:      return .CUBE, c.half_extents
  case physics.CylinderCollider: return .CYLINDER, {c.radius, c.half_height, c.radius}
  }
  return .SPHERE, 1
}

advance :: proc(app: ^App) {
  physics.step(&app.phys, STEP_DT)
  mjolnir.sync_bodies(&app.scene, &app.phys)
  app.steps += 1
}

rewind :: proc(app: ^App, steps: int) {
  load(app, app.scenario)
  for _ in 0 ..< steps do advance(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  controls(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  if steps, ok := app.rewind_to.?; ok {
    app.rewind_to = nil
    rewind(app, steps)
  }
  if app.playing {
    app.banked = min(app.banked + dt * app.speed, STEP_DT * MAX_STEPS_PER_FRAME)
    for app.banked >= STEP_DT {
      app.banked -= STEP_DT
      advance(app)
    }
  }
  draw_contacts(app)
  draw_velocities(app)
  draw_colliders(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw_contacts :: proc(app: ^App) {
  for &c in physics.contacts(&app.phys) {
    for p in c.points[:c.count] {
      render.debug_point(&app.renderer, p.point, 0.08, {1, 0.9, 0, 1}, 0, true)
      render.debug_arrow(&app.renderer, p.point, p.point + c.normal * 0.5, {0, 1, 1, 1}, 0, true)
      if p.base_separation < 0 {
        render.debug_segment(&app.renderer, p.point, p.point - c.normal * p.base_separation, {1, 0, 1, 1}, 0, true)
      }
      if p.normal_impulse > 0 {
        length := clamp(p.normal_impulse / STEP_DT * 0.05, 0.1, 3)
        render.debug_arrow(&app.renderer, p.point, p.point - c.normal * length, {1, 0.25, 0.2, 1}, 0, true)
      }
    }
  }
}

draw_velocities :: proc(app: ^App) {
  for t in app.bodies {
    b := physics.body(&app.phys, t.handle) or_continue
    if b.inv_mass == 0 || b.is_sleeping do continue
    render.debug_arrow(&app.renderer, b.position, b.position + b.velocity * 0.25, {0.3, 1, 0.3, 1}, 0, true)
  }
}

draw_colliders :: proc(app: ^App) {
  white := [4]f32{1, 1, 1, 1}
  for t in app.bodies {
    b := physics.body(&app.phys, t.handle) or_continue
    render.debug_axes(&app.renderer, b.position, b.rotation, 1, 0, true)
    switch c in t.collider {
    case physics.SphereCollider:
      render.debug_sphere(&app.renderer, b.position, c.radius, white, 0, true)
    case physics.BoxCollider:
      render.debug_cube(&app.renderer, b.position, b.rotation, c.half_extents, white, 0, true)
    case physics.CylinderCollider:
      axis := linalg.quaternion_mul_vector3(b.rotation, [3]f32{0, 1, 0})
      render.debug_circle(&app.renderer, b.position + axis * c.half_height, axis, c.radius, white, 0, true)
      render.debug_circle(&app.renderer, b.position - axis * c.half_height, axis, c.radius, white, 0, true)
    }
  }
}

name_of :: proc(app: ^App, handle: physics.BodyHandle) -> string {
  for t in app.bodies do if t.handle == handle do return t.name
  return "?"
}

step_forward :: proc(app: ^App) {
  app.playing = false
  advance(app)
}

step_back :: proc(app: ^App) {
  app.playing = false
  app.rewind_to = max(app.steps - 1, 0)
}

controls :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if !app.input.keyboard_captured {
    if input.key_pressed(&app.input, .SPACE) do app.playing = !app.playing
    if input.key_pressed(&app.input, .R) do app.rewind_to = 0
    if input.key_pressed(&app.input, .RIGHT) || input.key_repeated(&app.input, .RIGHT) do step_forward(app)
    if input.key_pressed(&app.input, .LEFT) || input.key_repeated(&app.input, .LEFT) do step_back(app)
  }

  if debugui.window(&app.debug, "Collision", {20, 20, 360, 330}) {
    mu.layout_row(ctx, {110, 110, 110}, 0)
    for s in Scenario {
      if .SUBMIT in mu.button(ctx, fmt.tprint(s)) {
        app.playing = false
        load(app, s)
      }
    }
    mu.layout_row(ctx, {-1}, 0)
    mu.text(ctx, EXPECTED[app.scenario])
    mu.layout_row(ctx, {80, 80, 80, -1}, 0)
    if .SUBMIT in mu.button(ctx, "< Back") do step_back(app)
    if .SUBMIT in mu.button(ctx, "Pause" if app.playing else "Play") do app.playing = !app.playing
    if .SUBMIT in mu.button(ctx, "Step >") do step_forward(app)
    if .SUBMIT in mu.button(ctx, "Restart") do app.rewind_to = 0
    mu.layout_row(ctx, {60, -1}, 0)
    mu.label(ctx, "Speed")
    mu.slider(ctx, &app.speed, 0.05, 1)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Step %d   t = %.3f s", app.steps, f32(app.steps) * STEP_DT))
    mu.label(ctx, "Space play/pause, Left/Right step, R restart")
    mu.label(ctx, "yellow point, cyan normal A->B, magenta depth")
    mu.label(ctx, "red impulse on A, green velocity")
  }

  if debugui.window(&app.debug, "Bodies", {900, 20, 360, 280}, {.RIGHT, .TOP}) {
    mu.layout_row(ctx, {-1}, 0)
    momentum: [3]f32
    energy: f32
    for t in app.bodies {
      b := physics.body(&app.phys, t.handle) or_continue
      if b.inv_mass == 0 do continue
      momentum += b.velocity / b.inv_mass
      energy += 0.5 * linalg.length2(b.velocity) / b.inv_mass
    }
    mu.label(ctx, fmt.tprintf("Momentum (%.3f, %.3f, %.3f)", momentum.x, momentum.y, momentum.z))
    mu.label(ctx, fmt.tprintf("Linear kinetic energy %.3f J", energy))
    for t in app.bodies {
      b := physics.body(&app.phys, t.handle) or_continue
      if b.inv_mass == 0 do continue
      mu.label(ctx, fmt.tprintf("[%s] mass %.2f%s", t.name, 1 / b.inv_mass, " sleeping" if b.is_sleeping else ""))
      mu.label(ctx, fmt.tprintf("  position (%.3f, %.3f, %.3f)", b.position.x, b.position.y, b.position.z))
      mu.label(ctx, fmt.tprintf("  velocity (%.3f, %.3f, %.3f)", b.velocity.x, b.velocity.y, b.velocity.z))
      w := b.angular_velocity
      mu.label(ctx, fmt.tprintf("  spin     (%.3f, %.3f, %.3f)", w.x, w.y, w.z))
    }
  }

  if debugui.window(&app.debug, "Contacts", {900, 320, 360, 380}, {.RIGHT, .TOP}) {
    mu.layout_row(ctx, {-1}, 0)
    contacts := physics.contacts(&app.phys)
    if len(contacts) == 0 do mu.label(ctx, "No contacts")
    for &c in contacts {
      mu.label(ctx, fmt.tprintf("%s -> %s  n (%.2f, %.2f, %.2f)", name_of(app, c.body_a), name_of(app, c.body_b), c.normal.x, c.normal.y, c.normal.z))
      for p, i in c.points[:c.count] {
        mu.label(ctx, fmt.tprintf("  #%d  separation %+.4f  impulse %.4f", i, p.base_separation, p.normal_impulse))
      }
    }
  }
}
