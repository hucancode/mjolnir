// Sandbox: the general test. The Warrior holds a Sponza courtyard: a sprite warrior idles, runs and strikes, a city hides behind the walls (occlusion culling), with torches, orbiting shadow casters, physics, particles, a portal and bloom.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/physics"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

Model :: enum {
  SPONZA,
  WARRIOR,
  DAMAGED_HELMET,
  SUZANNE,
  HAMMER,
}

MODEL_FILES := [Model][]u8 {
  .SPONZA         = #load("assets/Sponza.glb"),
  .WARRIOR        = #load("assets/Warrior.glb"),
  .DAMAGED_HELMET = #load("assets/DamagedHelmet.glb"),
  .SUZANNE        = #load("assets/Suzanne.glb"),
  .HAMMER         = #load("assets/Mjolnir.glb"),
}

SPONZA_SCALE :: 2
MID :: -0.6

VIEW_TARGET :: [3]f32{0, 1.5, MID}
VIEW_YAW :: math.PI - 0.3
VIEW_PITCH :: 0.4
VIEW_DISTANCE :: 6

TORCHES := [?][3]f32{{-15, 2.6, 2.4}, {-5, 2.6, 2.4}, {5, 2.6, 2.4}, {15, 2.6, 2.4}, {-15, 2.6, -3.8}, {-5, 2.6, -3.8}, {5, 2.6, -3.8}, {15, 2.6, -3.8}}
ORBIT_LIGHTS :: 6
TORCH_INTENSITY :: 40
MAX_BALLS :: 40

SpriteClip :: struct {
  first, count: u32,
}
SPRITE_IDLE :: SpriteClip{0, 6}
SPRITE_RUN :: SpriteClip{6, 8}
SPRITE_ACTIONS := [?]SpriteClip{{14, 12}, {42, 8}, {84, 7}, {76, 8}, {63, 10}}
SPRITE_FPS :: 10
SPRITE_HEIGHT :: 2
SPRITE_ASPECT :: f32(69.0 / 44.0)
SPRITE_LANE :: [2]f32{3.4, 6.6}
SPRITE_SPEED :: 2.4

Actor :: struct {
  model:    Model,
  instance: gltf.Instance,
}

Ball :: struct {
  node: world.NodeHandle,
  body: physics.BodyHandle,
}

App :: struct {
  platform:      platform.Platform,
  scene:         world.World,
  renderer:      render.Renderer,
  debug:         debugui.Context,
  input:         input.State,
  phys:          physics.World,
  orbit:         render.Orbit,
  time:          f32,
  models:        [Model]gltf.Model,
  actors:        [dynamic]Actor,
  spinners:      [dynamic]world.NodeHandle,
  balls:         [dynamic]Ball,
  torches:       [len(TORCHES)]render.LightHandle,
  hero:          int,
  hero_intro:    animation.LayerHandle,
  hammer:        world.NodeHandle,
  lights_root:   world.NodeHandle,
  portal_camera: render.CameraHandle,
  portal:        render.MaterialHandle,
  sprite:        render.MaterialHandle,
  sprite_node:   world.NodeHandle,
  sprite_clip:   SpriteClip,
  sprite_once:   bool,
  sprite_time:   f32,
  sprite_left:   f32,
  sprite_x:      f32,
  sprite_facing: f32,
  ball_look:     render.MeshAttachment,
  objects:       int,
  bloom:         bool,
  spin_lights:   bool,
  sun_angle:     f32,
  sun:           world.NodeHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Sandbox") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  if !physics.init(&app.phys) do return
  mjolnir.run(mjolnir.Loop(App){app = app, setup = setup, update = update, render = draw, shutdown = shutdown})
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  for &model, m in app.models {
    model = gltf.model_create(&app.renderer, MODEL_FILES[m]) or_else {}
    if len(model.nodes) == 0 do log.errorf("cannot load %v", m)
  }
  r := &app.renderer
  r.ibl_intensity = 0.4
  app.sun_angle = 62
  app.sun = mjolnir.spawn(&app.scene, r, render.light_create(r, render.make_directional_light({1, 0.92, 0.8}, 4, 45)))
  app.bloom = true
  app.spin_lights = true
  app.orbit = {VIEW_YAW, VIEW_PITCH, VIEW_DISTANCE, VIEW_TARGET}
  set_effects(app)

  actor(app, .SPONZA, {}, SPONZA_SCALE)
  courtyard(app)
  lights(app)
  particles(app)
  crates(app)
  portal(app)
  hidden_city(app)
  app.ball_look = render.primitive(r, .SPHERE, .ORANGE)
  return .READY
}

actor :: proc(app: ^App, model: Model, position: [3]f32, scale: f32 = 1, yaw: f32 = 0, clip := "") -> ^Actor {
  a := Actor{model = model, instance = gltf.instance_create(&app.models[model], &app.scene, &app.renderer)}
  world.transform(&app.scene, a.instance.root)^ = {position, linalg.quaternion_angle_axis(yaw, linalg.VECTOR3F32_Y_AXIS), scale}
  for &animator, i in a.instance.animators do animation.play(&animator, &app.models[model].rigs[i], clip)
  append(&app.actors, a)
  return &app.actors[len(app.actors) - 1]
}

mesh :: proc(app: ^App, look: render.MeshAttachment, position: [3]f32, scale: [3]f32 = 1, parent: world.NodeHandle = {}) -> world.NodeHandle {
  app.objects += 1
  return mjolnir.spawn(&app.scene, &app.renderer, look, position, scale = scale, parent = parent)
}

courtyard :: proc(app: ^App) {
  r := &app.renderer
  stone := render.material_create(r, render.make_material(base_color_factor = {0.55, 0.52, 0.48, 1}, roughness_factor = 0.7))
  pedestal := render.primitive(r, .CYLINDER, stone)
  mesh(app, pedestal, {0, 0.3, MID}, {1.2, 0.3, 1.2})
  app.hero = len(app.actors)
  hero := actor(app, .WARRIOR, {0, 0.6, MID})
  app.hero_intro = animation.play(&hero.instance.animators[0], &app.models[.WARRIOR].rigs[0], "intro", .ONCE)
  app.hammer = world.spawn(&app.scene, {0, 4.2, MID})
  hammer := actor(app, .HAMMER, {}, 0.6)
  world.set_parent(&app.scene, hammer.instance.root, app.hammer)
  mesh(app, pedestal, {-17, 0.5, MID}, {0.9, 0.5, 0.9})
  helmet := actor(app, .DAMAGED_HELMET, {-17, 1, MID}, 0.6)
  append(&app.spinners, helmet.instance.root)
  spot := world.spawn(&app.scene, {-17, 7, MID})
  world.transform(&app.scene, spot).rotation = linalg.quaternion_angle_axis(-math.PI / 2, linalg.VECTOR3F32_X_AXIS)
  render.attach(r, spot, render.light_create(r, render.make_spot_light({1, 0.9, 0.75}, 400, 10, math.PI * 0.12)))
  suzanne := actor(app, .SUZANNE, {0, 9, MID}, 1.4)
  append(&app.spinners, suzanne.instance.root)
}

lights :: proc(app: ^App) {
  r := &app.renderer
  sconce := render.primitive(r, .CYLINDER, .BLACK)
  for p, i in TORCHES {
    mesh(app, sconce, p - {0, 0.25, 0}, {0.08, 0.2, 0.08})
    app.torches[i] = render.light_create(r, render.make_point_light({1, 0.55, 0.2}, TORCH_INTENSITY, 8, cast_shadow = false))
    mjolnir.spawn(&app.scene, r, app.torches[i], p + {0, 0.2, 0})
  }
  app.lights_root = world.spawn(&app.scene, {0, 5, MID})
  for i in 0 ..< ORBIT_LIGHTS {
    angle := f32(i) / ORBIT_LIGHTS * 2 * math.PI
    color := [3]f32{0.5 + 0.5 * math.cos(angle), 0.5 + 0.5 * math.cos(angle + 2.1), 0.5 + 0.5 * math.cos(angle + 4.2)}
    lamp := mjolnir.spawn(&app.scene, r, render.light_create(r, render.make_point_light(color, 60, 10)), {math.cos(angle) * 12, 0, math.sin(angle) * 2}, parent = app.lights_root)
    bulb := render.material_create(r, render.make_material(base_color_factor = {color.r, color.g, color.b, 1}, emissive_factor = 8))
    mesh(app, render.primitive(r, .SPHERE, bulb, no_shadow = true), {0, 0.35, 0}, 0.12, lamp)
  }
}

particles :: proc(app: ^App) {
  r := &app.renderer
  flame := render.texture_create(r, #load("assets/particles/flame_03.png"))
  star := render.texture_create(r, #load("assets/particles/star_07.png"))
  spark := render.texture_create(r, #load("assets/particles/light_01.png"))
  fire := render.emitter_create(r, render.make_emitter(flame, emission_rate = 45, initial_velocity = {0, 1.2, 0}, velocity_spread = 0.25, color_start = {1, 0.7, 0.3, 1}, color_end = {1, 0.15, 0, 0}, particle_lifetime = 0.7, position_spread = 0.08, size_start = 180, size_end = 40, weight = -0.1))
  for p in TORCHES do mjolnir.spawn(&app.scene, r, fire, p)
  sparks := render.emitter_create(r, render.make_emitter(spark, emission_rate = 60, initial_velocity = {0, 0.4, 0}, velocity_spread = 1.2, color_start = {0.6, 0.8, 1, 1}, color_end = {0.2, 0.4, 1, 0}, particle_lifetime = 1.4, position_spread = 0.6, size_start = 90, size_end = 10, weight = 0.05))
  mjolnir.spawn(&app.scene, r, sparks, {0, 1.2, 0}, parent = app.hammer)
  fountain := render.emitter_create(r, render.make_emitter(star, emission_rate = 140, initial_velocity = {0, 5, 0}, velocity_spread = 0.6, color_start = {1, 0.9, 0.3, 1}, color_end = {1, 0.3, 0.6, 0}, particle_lifetime = 2.6, position_spread = 0.15, size_start = 160, size_end = 60))
  mjolnir.spawn(&app.scene, r, fountain, {-8, 0.2, MID})
  mjolnir.spawn(&app.scene, r, render.force_field_create(r, render.make_force_field(area_of_effect = 3, strength = 4, tangent_strength = 6)), {-8, 3.5, MID})
}

crates :: proc(app: ^App) {
  physics.body_create(&app.phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {30, 0.5, 30}})
  colors := [?]render.Color{.RED, .YELLOW, .GREEN, .CYAN, .BLUE, .MAGENTA}
  half :: 0.25
  for layer in 0 ..< 5 {
    for x in 0 ..< 3 {
      for z in 0 ..< 3 {
        p := [3]f32{8 + (f32(x) - 1) * 2 * half, half + f32(layer) * 2 * half, MID + (f32(z) - 1) * 2 * half}
        node := mesh(app, render.primitive(&app.renderer, .CUBE, colors[(x + z + layer) % len(colors)]), p, half)
        physics.body_create(&app.phys, p, collider = physics.BoxCollider{half_extents = half}, mass = 2, user = world.Handle(node))
      }
    }
  }
}

portal :: proc(app: ^App) {
  r := &app.renderer
  app.portal_camera = render.camera_create(r, {512, 512}, render.make_camera({0, 40, MID + 0.01}, {0, 0, MID}, 0.9, far = 100))
  app.portal = render.material_create(r, render.make_material(emissive_factor = 0.2))
  frame := render.primitive(r, .CUBE, .BLACK)
  mesh(app, frame, {-21.6, 3.2, MID}, {0.1, 2.3, 2.3})
  screen := mesh(app, render.primitive(r, .QUAD_XY, app.portal, no_shadow = true), {-21.45, 3.2, MID}, {2.1, 2.1, 1})
  world.transform(&app.scene, screen).rotation = linalg.quaternion_angle_axis(math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  sheet := render.texture_create(r, #load("assets/Warrior_Sheet-Effect.png"))
  app.sprite = render.material_create(r, render.make_material(.SPRITE, albedo_texture = sheet, frame_columns = 6, frame_rows = 17))
  app.sprite_node = mesh(app, render.primitive(r, .QUAD_XY, app.sprite, no_shadow = true), {})
  app.sprite_x, app.sprite_facing = SPRITE_LANE.x, 1
  sprite_play(app, SPRITE_IDLE, false, 3)
}

hidden_city :: proc(app: ^App) {
  shapes := [?]render.Primitive{.CUBE, .SPHERE, .CONE, .CYLINDER}
  colors := [?]render.Color{.RED, .YELLOW, .GREEN, .CYAN, .BLUE, .MAGENTA, .WHITE}
  rng := rand.create(7)
  context.random_generator = rand.default_random_generator(&rng)
  for x := f32(-52); x <= 52; x += 2 {
    for z := f32(-52); z <= 52; z += 2 {
      if abs(x) < 33 && abs(z) < 22 do continue
      height := 0.4 + rand.float32() * 2
      look := render.primitive(&app.renderer, rand.choice(shapes[:]), rand.choice(colors[:]), no_shadow = true)
      mesh(app, look, {x, height, z}, {0.7, height, 0.7})
    }
  }
}

set_effects :: proc(app: ^App) {
  render.main_camera(&app.renderer).effects[0] = render.make_effect(render.BloomEffect{threshold = 1, intensity = 0.35, blur_radius = 24}) if app.bloom else {}
}

shutdown :: proc(app: ^App) {
  for &a in app.actors do gltf.destroy(&a.instance, &app.scene, &app.renderer)
  for &m in app.models do gltf.destroy(&m, &app.renderer)
  delete(app.actors)
  delete(app.spinners)
  delete(app.balls)
  physics.shutdown(&app.phys)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  r := &app.renderer
  render.lock(r)
  platform.read_input(&app.platform, &app.input)
  panel(app)
  app.time += dt
  mjolnir.orbit_drag(&app.orbit, render.main_camera(r), &app.input)
  if !app.input.keyboard_captured && input.key_pressed(&app.input, .SPACE) do shoot(app)
  animate(app, dt)
  physics.step(&app.phys, dt)
  mjolnir.sync_bodies(&app.scene, &app.phys)
  mjolnir.update(&app.scene, r, dt)
  for &a in app.actors do gltf.animate(&a.instance, &app.models[a.model], &app.scene, r, dt)
}

animate :: proc(app: ^App, dt: f32) {
  r := &app.renderer
  t := app.time
  hero := &app.actors[app.hero]
  if animation.clip_done(&hero.instance.animators[0], app.hero_intro) do animation.play(&hero.instance.animators[0], &app.models[.WARRIOR].rigs[0], "idle")
  for node in app.spinners do world.transform(&app.scene, node).rotation *= linalg.quaternion_angle_axis(dt * 0.6, linalg.VECTOR3F32_Y_AXIS)
  world.transform(&app.scene, app.hammer).position = {0, 4.2 + 0.25 * math.sin(t * 1.7), MID}
  world.transform(&app.scene, app.hammer).rotation = linalg.quaternion_angle_axis(t * 1.3, linalg.VECTOR3F32_Y_AXIS)
  if app.spin_lights do world.transform(&app.scene, app.lights_root).rotation *= linalg.quaternion_angle_axis(dt * 0.35, linalg.VECTOR3F32_Y_AXIS)
  for h, i in app.torches {
    if l, ok := render.light(r, h); ok do l.intensity = TORCH_INTENSITY * (0.8 + 0.2 * math.sin(t * 13 + f32(i) * 1.7) * math.sin(t * 7.3 + f32(i)))
  }
  sprite_step(app, dt)
  if m, ok := render.material(r, app.portal); ok do m.albedo_texture = render.camera_image(r, app.portal_camera, .FINAL_IMAGE, previous_frame = true)
  elevation := app.sun_angle * math.RAD_PER_DEG
  sun := [3]f32{-math.cos(elevation) * 0.35, -math.sin(elevation), -math.cos(elevation)}
  world.transform(&app.scene, app.sun).rotation = linalg.quaternion_from_forward_and_up(sun, [3]f32{0, 1, 0})
}

shoot :: proc(app: ^App) {
  cam := render.main_camera(&app.renderer)
  forward := -linalg.mul(cam.rotation, linalg.VECTOR3F32_Z_AXIS)
  if len(app.balls) == MAX_BALLS {
    physics.destroy(&app.phys, app.balls[0].body)
    world.destroy(&app.scene, app.balls[0].node)
    ordered_remove(&app.balls, 0)
  }
  at := cam.position + forward
  node := mesh(app, app.ball_look, at, 0.25)
  body := physics.body_create(&app.phys, at, collider = physics.SphereCollider{radius = 0.25}, mass = 6, user = world.Handle(node))
  physics.set_velocity(&app.phys, body, forward * 22)
  append(&app.balls, Ball{node, body})
}

panel :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Sandbox", {20, 20, 280, 330}, {}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Meshes: %d   Actors: %d", app.objects, len(app.actors)))
    mu.label(ctx, fmt.tprintf("Lights: %d + sun   Balls: %d", len(TORCHES) + ORBIT_LIGHTS + 1, len(app.balls)))
    if .CHANGE in mu.checkbox(ctx, "Bloom", &app.bloom) do set_effects(app)
    mu.checkbox(ctx, "Orbit lights", &app.spin_lights)
    mu.layout_row(ctx, {80, -1}, 0)
    mu.label(ctx, "Sun angle")
    mu.slider(ctx, &app.sun_angle, 10, 90, 1, "%.0f")
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Space: shoot   Drag: orbit   Scroll: zoom")
  }
  if debugui.window(&app.debug, "GPU", {980, 20, 280, 300}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    timings := render.gpu_timings(&app.renderer)
    if len(timings) == 0 do mu.label(ctx, "No GPU timers on this device")
    mu.layout_row(ctx, {170, -1}, 0)
    for t in timings {
      mu.label(ctx, fmt.tprintf("%*s%s", int(t.depth) * 2, "", t.name))
      mu.label(ctx, fmt.tprintf("%.3f ms", t.ms))
    }
  }
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

sprite_play :: proc(app: ^App, clip: SpriteClip, once: bool, seconds: f32 = 0) {
  app.sprite_clip, app.sprite_once, app.sprite_time, app.sprite_left = clip, once, 0, seconds
}

sprite_step :: proc(app: ^App, dt: f32) {
  app.sprite_time += dt
  app.sprite_left -= dt
  frame := u32(app.sprite_time * SPRITE_FPS)
  running := app.sprite_clip == SPRITE_RUN
  if app.sprite_once && frame >= app.sprite_clip.count {
    sprite_play(app, SPRITE_IDLE, false, 2 + 3 * rand.float32())
    frame = 0
  } else if !app.sprite_once && app.sprite_left <= 0 {
    roll := rand.float32()
    if !running && roll < 0.5 do sprite_play(app, SPRITE_RUN, false, 2 + 3 * rand.float32())
    else if roll < 0.8 do sprite_play(app, rand.choice(SPRITE_ACTIONS[:]), true)
    else do sprite_play(app, SPRITE_IDLE, false, 2 + 2 * rand.float32())
    frame = 0
  }
  if app.sprite_clip == SPRITE_RUN {
    app.sprite_x += app.sprite_facing * SPRITE_SPEED * dt
    if app.sprite_x < SPRITE_LANE.x || app.sprite_x > SPRITE_LANE.y do app.sprite_facing = -app.sprite_facing
    app.sprite_x = clamp(app.sprite_x, SPRITE_LANE.x, SPRITE_LANE.y)
  }
  clip := app.sprite_clip
  render.material(&app.renderer, app.sprite).frame_index = clip.first + (min(frame, clip.count - 1) if app.sprite_once else frame % clip.count)
  world.transform(&app.scene, app.sprite_node).position = {app.sprite_x, SPRITE_HEIGHT / 2, MID}
  world.transform(&app.scene, app.sprite_node).scale = {app.sprite_facing * SPRITE_HEIGHT * SPRITE_ASPECT / 2, SPRITE_HEIGHT / 2, 1}
}
