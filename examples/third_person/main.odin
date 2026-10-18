// Third-person character: a glTF knight runs, jumps and attacks on physics ground.
package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/font"
import "../../mjolnir/geometry"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/physics"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"

Action :: enum {
  IDLE,
  RUN,
  JUMP,
  ATTACK,
}

CLIPS := [Action]string {
  .IDLE   = "Idle",
  .RUN    = "Running_A",
  .JUMP   = "Jump_Full_Short",
  .ATTACK = "1H_Melee_Attack_Chop",
}
UNUSED_PROPS := [?]string{"1H_Sword_Offhand", "Badge_Shield", "Rectangle_Shield", "Spike_Shield", "2H_Sword"}

RUN_SPEED :: 5.0
JUMP_SPEED :: 7.0
BODY_RADIUS :: 0.5
BODY_HEIGHT :: 2.4
CROSS_FADE :: 0.15

App :: struct {
  window:      platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  phys:        physics.World,
  input:       input.State,
  font:        font.Font,
  orbit:       render.Orbit,
  knight:      gltf.Scene,
  rig:         gltf.RigHandle,
  animator:    anim.Animator,
  layers:      [Action]anim.LayerHandle,
  body:        physics.BodyHandle,
  body_node:   world.NodeHandle,
  model:       world.NodeHandle,
  action:      Action,
  action_time: f32,
  animated:    bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Third Person") do return
  if !render.init(&app.renderer, "Third Person", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  if !physics.init(&app.phys, gravity = {0, -20, 0}) do return
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

setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !font.init(&app.font, #load("../../assets/Outfit-Regular.ttf")) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  spawn_box(app, {0, -0.5, 0}, {30, 0.5, 30}, .GRAY)
  spawn_box(app, {4, 0.5, 3}, {1, 0.5, 1}, .RED)
  spawn_box(app, {-5, 1, -2}, {1.5, 1, 1}, .BLUE)
  spawn_box(app, {1, 0.25, -6}, {3, 0.25, 1}, .YELLOW)
  spawn_box(app, {-3, 0.75, 6}, {0.75, 0.75, 0.75}, .GREEN)

  start := [3]f32{0, BODY_HEIGHT / 2, 0}
  app.body_node = world.spawn(&app.scene, start)
  app.body = physics.body_create(
    &app.phys,
    start,
    collider = physics.CylinderCollider{radius = BODY_RADIUS, height = BODY_HEIGHT},
    mass = 70,
    user = world.Handle(app.body_node),
  )
  params := physics.body_params(&app.phys, app.body)
  params.enable_rotation = false
  params.friction = 0
  app.model = world.spawn(&app.scene, {0, -BODY_HEIGHT / 2, 0}, parent = app.body_node)

  ok: bool
  app.knight, ok = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/Knight.glb"), parent = app.model)
  if !ok || len(app.knight.skinned) == 0 do return true
  app.rig = app.knight.skinned[0].rig
  rig := &app.knight.rigs[app.rig]
  anim.animator_init(&app.animator, rig)
  for name, action in CLIPS {
    mode: anim.PlayMode = .LOOP if action == .IDLE || action == .RUN else .ONCE
    weight: f32 = 1 if action == .IDLE else 0
    app.layers[action] = anim.layer_create(&app.animator, rig, anim.ClipParams{clip = anim.clip_find(rig, name), speed = 1, mode = mode}, weight = weight)
  }
  app.animated = true
  for prop in UNUSED_PROPS do world.set_visible(&app.scene, world.find(&app.scene, prop, app.model), false)

  sun := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(sun.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.96, 0.9}, 3, shadow_radius = 20)))
  world.rotate(&app.scene, sun, math.PI * 0.35, linalg.VECTOR3F32_X_AXIS)

  render.camera_look_at(render.main_camera(&app.renderer), {0, 5, 9}, {0, 1.5, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1.5, 0})
  return true
}

spawn_box :: proc(app: ^App, position, half_extents: [3]f32, color: render.Color) {
  node := world.spawn(&app.scene, position)
  physics.body_create(&app.phys, position, collider = physics.BoxCollider{half_extents = half_extents})
  render.attach(&app.renderer, render.SlotHandle(node.index), render.primitive(&app.renderer, .CUBE, color))
  world.scale(&app.scene, node, half_extents)
}

shutdown :: proc(app: ^App) {
  anim.animator_destroy(&app.animator)
  gltf.scene_destroy(&app.knight, &app.scene, &app.renderer)
  font.destroy(&app.font)
  physics.shutdown(&app.phys)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  drag := app.input.mouse_delta if input.mouse_down(&app.input, .RIGHT) else 0
  render.orbit_drag(&app.orbit, drag, app.input.scroll.y, min_distance = 3, max_distance = 20)

  move := move_direction(app)
  grounded := on_ground(app)
  app.action_time += dt
  finished := anim.clip_done(&app.animator, app.layers[app.action])
  switch {
  case app.action == .ATTACK && !finished:
  case grounded && input.mouse_pressed(&app.input, .LEFT):
    set_action(app, .ATTACK)
  case grounded && input.key_pressed(&app.input, .SPACE):
    set_action(app, .JUMP)
    physics.apply_impulse(&app.phys, app.body, {0, JUMP_SPEED * 70, 0})
  case app.action == .JUMP && !(grounded && app.action_time > 0.3):
  case linalg.length(move) > 0:
    set_action(app, .RUN)
  case:
    set_action(app, .IDLE)
  }

  body := physics.body(&app.phys, app.body)
  velocity := move * RUN_SPEED if app.action != .ATTACK else 0
  physics.set_velocity(&app.phys, app.body, {velocity.x, body.velocity.y, velocity.z})
  if linalg.length(move) > 0 do world.rotate(&app.scene, app.model, math.atan2(move.x, move.z))
  physics.step(&app.phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))

  if app.animated {
    anim.animator_update(&app.animator, &app.knight.rigs[app.rig], dt)
    gltf.pose_joints(&app.knight, &app.scene, app.rig, &app.animator)
  }
  app.orbit.target = physics.body(&app.phys, app.body).position + {0, 0.3, 0}
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for s in app.knight.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), app.animator.palette)
  render.update(&app.renderer, dt)
}

move_direction :: proc(app: ^App) -> [3]f32 {
  cam := render.main_camera(&app.renderer)
  forward := render.camera_forward(cam) * {1, 0, 1}
  right := render.camera_right(cam) * {1, 0, 1}
  move := forward * input.axis(&app.input, .S, .W) + right * input.axis(&app.input, .A, .D)
  return linalg.normalize0(move)
}

on_ground :: proc(app: ^App) -> bool {
  feet := physics.body(&app.phys, app.body).position - {0, BODY_HEIGHT / 2 + 0.01, 0}
  return physics.raycast(&app.phys, geometry.Ray{origin = feet, direction = {0, -1, 0}}, 0.1, first_hit = true).hit
}

set_action :: proc(app: ^App, action: Action) {
  if action == app.action do return
  anim.layer_fade(&app.animator, app.layers[app.action], 0, CROSS_FADE)
  anim.layer_fade(&app.animator, app.layers[action], 1, CROSS_FADE)
  anim.clip_seek(&app.animator, app.layers[action], 0)
  app.action = action
  app.action_time = 0
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  commands := make([dynamic]render.RenderCommand, context.temp_allocator)
  label(app, &commands, fmt.tprintf("%v", app.action), {20, 20}, 32)
  label(app, &commands, "WASD run   Space jump   Left click attack   Right drag look", {20, 64}, 20)
  pixels, size, changed := font.atlas(&app.font)
  render.stage_overlay(&app.renderer, {commands = commands[:], atlas = pixels if changed else nil, atlas_size = size})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

label :: proc(app: ^App, commands: ^[dynamic]render.RenderCommand, text: string, position: [2]f32, size: f32) {
  glyphs := make([dynamic]font.Glyph, context.temp_allocator)
  font.glyphs(&app.font, text, position * platform.dpi_scale(&app.window), size * platform.dpi_scale(&app.window), &glyphs)
  append(commands, render.RenderCommand{shape = render.DrawTextCommand{glyphs = glyphs[:], color = {255, 255, 255, 255}}})
}
