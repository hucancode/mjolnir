// Third-person adventure: pick a hero, fight skeleton waves across levels, grab power-ups.
// Characters and props: KayKit Character Pack Adventurers 1.0 and Skeletons 1.0 by Kay Lousberg
// (www.kaylousberg.com, CC0). Particle textures: Kenney Particle Pack (www.kenney.nl, CC0).
package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/font"
import "../../mjolnir/geometry"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/bake"
import "../../mjolnir/navigation/crowd"
import "../../mjolnir/physics"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/ui"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

CREDITS :: "Characters & props: KayKit by Kay Lousberg (CC0)   Particles: Kenney (CC0)"

ARENA :: 14
BODY_RADIUS :: 0.5
BODY_HEIGHT :: 2.4
JUMP_SPEED :: 8
REACH :: 2.2
SIGHT :: 16
BUFF_TIME :: 10
BURST_TIME :: 0.15
DESPAWN_TIME :: 2.5
RESULT_DELAY :: 1.5
CROSS_FADE :: 0.15

Hero :: struct {
  name:   string,
  model:  []u8,
  props:  []string,
  attack: string,
  health: f32,
  speed:  f32,
  damage: f32,
}

HEROES := [?]Hero {
  {"Knight", #load("../../assets/kaykit_adventurers/Knight.glb"), {"1H_Sword", "Round_Shield"}, "1H_Melee_Attack_Chop", 140, 5, 22},
  {"Barbarian", #load("../../assets/kaykit_adventurers/Barbarian.glb"), {"1H_Axe", "Barbarian_Round_Shield"}, "1H_Melee_Attack_Slice_Diagonal", 170, 4.5, 26},
  {"Mage", #load("../../assets/kaykit_adventurers/Mage.glb"), {"2H_Staff"}, "2H_Melee_Attack_Spin", 100, 5.5, 34},
  {"Rogue", #load("../../assets/kaykit_adventurers/Rogue.glb"), {"Knife", "Knife_Offhand"}, "Dualwield_Melee_Attack_Stab", 110, 6.5, 24},
  {"Rogue_Hooded", #load("../../assets/kaykit_adventurers/Rogue_Hooded.glb"), {"Knife", "Knife_Offhand"}, "Dualwield_Melee_Attack_Slice", 110, 6.5, 24},
}

HERO_PROPS := [?]string {
  "1H_Sword", "1H_Sword_Offhand", "2H_Sword", "Badge_Shield", "Rectangle_Shield", "Round_Shield", "Spike_Shield",
  "1H_Axe", "1H_Axe_Offhand", "2H_Axe", "Barbarian_Round_Shield", "Mug",
  "1H_Wand", "2H_Staff", "Spellbook", "Spellbook_open",
  "Knife", "Knife_Offhand", "1H_Crossbow", "2H_Crossbow", "Throwable",
}

Shot :: enum {
  NONE,
  ARROW,
  FIREBALL,
}

EnemyKind :: enum {
  MINION,
  ROGUE,
  MAGE,
  WARRIOR,
  BOSS,
}

Foe :: struct {
  model:        []u8,
  right, left:  []u8,
  attack:       string,
  shot:         Shot,
  health:       f32,
  speed:        f32,
  damage:       f32,
  range:        f32,
  cooldown:     f32,
  windup:       f32,
  scale:        f32,
  score:        int,
}

FOES := [EnemyKind]Foe {
  .MINION = {
    model = #load("../../assets/kaykit_skeletons/Skeleton_Minion.glb"),
    right = #load("../../assets/kaykit_skeletons/Skeleton_Blade.glb"),
    left = #load("../../assets/kaykit_skeletons/Skeleton_Shield_Small_A.glb"),
    attack = "1H_Melee_Attack_Chop", health = 40, speed = 2.6, damage = 10, range = 1.8, cooldown = 1.4, windup = 0.45, scale = 1, score = 10,
  },
  .ROGUE = {
    model = #load("../../assets/kaykit_skeletons/Skeleton_Rogue.glb"),
    right = #load("../../assets/kaykit_skeletons/Skeleton_Crossbow.glb"),
    attack = "1H_Ranged_Shoot", shot = .ARROW, health = 30, speed = 3.2, damage = 8, range = 9, cooldown = 2, windup = 0.3, scale = 1, score = 15,
  },
  .MAGE = {
    model = #load("../../assets/kaykit_skeletons/Skeleton_Mage.glb"),
    right = #load("../../assets/kaykit_skeletons/Skeleton_Staff.glb"),
    attack = "Spellcast_Shoot", shot = .FIREBALL, health = 30, speed = 2.4, damage = 14, range = 10, cooldown = 2.6, windup = 0.5, scale = 1, score = 20,
  },
  .WARRIOR = {
    model = #load("../../assets/kaykit_skeletons/Skeleton_Warrior.glb"),
    right = #load("../../assets/kaykit_skeletons/Skeleton_Axe.glb"),
    left = #load("../../assets/kaykit_skeletons/Skeleton_Shield_Large_A.glb"),
    attack = "1H_Melee_Attack_Slice_Diagonal", health = 90, speed = 2.2, damage = 18, range = 2, cooldown = 1.8, windup = 0.5, scale = 1.15, score = 30,
  },
  .BOSS = {
    model = #load("../../assets/kaykit_skeletons/Skeleton_Warrior.glb"),
    right = #load("../../assets/kaykit_skeletons/Skeleton_Axe.glb"),
    left = #load("../../assets/kaykit_skeletons/Skeleton_Shield_Large_B.glb"),
    attack = "2H_Melee_Attack_Spin", health = 320, speed = 2.4, damage = 26, range = 3, cooldown = 1.6, windup = 0.6, scale = 1.8, score = 200,
  },
}

ARROW_MODEL :: #load("../../assets/kaykit_skeletons/Skeleton_Arrow.glb")

Power :: enum {
  HEAL,
  STRENGTH,
  SPEED,
  SHIELD,
}

POWER_MODELS := [Power][]u8 {
  .HEAL     = #load("../../assets/kaykit_adventurers/mug_full.glb"),
  .STRENGTH = #load("../../assets/kaykit_adventurers/spellbook_open.glb"),
  .SPEED    = #load("../../assets/kaykit_adventurers/smokebomb.glb"),
  .SHIELD   = #load("../../assets/kaykit_adventurers/shield_badge_color.glb"),
}

DECOR := [?][]u8 {
  #load("../../assets/kaykit_adventurers/arrow.glb"),
  #load("../../assets/kaykit_adventurers/arrow_bundle.glb"),
  #load("../../assets/kaykit_adventurers/axe_1handed.glb"),
  #load("../../assets/kaykit_adventurers/axe_2handed.glb"),
  #load("../../assets/kaykit_adventurers/crossbow_1handed.glb"),
  #load("../../assets/kaykit_adventurers/crossbow_2handed.glb"),
  #load("../../assets/kaykit_adventurers/dagger.glb"),
  #load("../../assets/kaykit_adventurers/mug_empty.glb"),
  #load("../../assets/kaykit_adventurers/quiver.glb"),
  #load("../../assets/kaykit_adventurers/shield_badge.glb"),
  #load("../../assets/kaykit_adventurers/shield_round.glb"),
  #load("../../assets/kaykit_adventurers/shield_round_barbarian.glb"),
  #load("../../assets/kaykit_adventurers/shield_round_color.glb"),
  #load("../../assets/kaykit_adventurers/shield_spikes.glb"),
  #load("../../assets/kaykit_adventurers/shield_spikes_color.glb"),
  #load("../../assets/kaykit_adventurers/shield_square.glb"),
  #load("../../assets/kaykit_adventurers/shield_square_color.glb"),
  #load("../../assets/kaykit_adventurers/spellbook_closed.glb"),
  #load("../../assets/kaykit_adventurers/staff.glb"),
  #load("../../assets/kaykit_adventurers/sword_1handed.glb"),
  #load("../../assets/kaykit_adventurers/sword_2handed.glb"),
  #load("../../assets/kaykit_adventurers/sword_2handed_color.glb"),
  #load("../../assets/kaykit_adventurers/wand.glb"),
  #load("../../assets/kaykit_skeletons/Skeleton_Arrow_Broken.glb"),
  #load("../../assets/kaykit_skeletons/Skeleton_Arrow_Broken_Half.glb"),
  #load("../../assets/kaykit_skeletons/Skeleton_Arrow_Half.glb"),
  #load("../../assets/kaykit_skeletons/Skeleton_Quiver.glb"),
  #load("../../assets/kaykit_skeletons/Skeleton_Shield_Small_B.glb"),
}

Box :: struct {
  center, half_extents: [3]f32,
}

Level :: struct {
  enemies:   []EnemyKind,
  obstacles: []Box,
  powers:    []Power,
}

LEVELS := [?]Level {
  {
    enemies = {.MINION, .MINION, .MINION},
    obstacles = {{{0, 1, -5}, {3, 1, 0.5}}, {{-6, 1, 4}, {0.5, 1, 2.5}}},
    powers = {.HEAL, .STRENGTH},
  },
  {
    enemies = {.MINION, .ROGUE, .MINION, .MAGE, .WARRIOR},
    obstacles = {{{-5, 1, -4}, {1.5, 1, 1.5}}, {{5, 1, -4}, {1.5, 1, 1.5}}, {{0, 1, 5}, {4, 1, 0.5}}},
    powers = {.HEAL, .SPEED, .SHIELD},
  },
  {
    enemies = {.BOSS, .MINION, .ROGUE, .MAGE, .WARRIOR, .MINION},
    obstacles = {{{-6, 1, 0}, {0.5, 1, 4}}, {{6, 1, 0}, {0.5, 1, 4}}, {{0, 1, 7}, {2, 1, 0.5}}},
    powers = {.HEAL, .HEAL, .STRENGTH, .SPEED, .SHIELD},
  },
}

Effect :: enum {
  HIT,
  DEATH,
  PICKUP,
  MAGIC,
  FIRE,
}

EFFECT_TEXTURES := [Effect][]u8 {
  .HIT    = #load("../../assets/particles/star_04.png"),
  .DEATH  = #load("../../assets/particles/smoke_04.png"),
  .PICKUP = #load("../../assets/particles/star_06.png"),
  .MAGIC  = #load("../../assets/particles/light_02.png"),
  .FIRE   = #load("../../assets/particles/flame_02.png"),
}

Clip :: enum {
  IDLE,
  RUN,
  JUMP,
  ATTACK,
  HIT,
  DEATH,
  CHEER,
}

CLIPS := [Clip]string {
  .IDLE   = "Idle",
  .RUN    = "Running_A",
  .JUMP   = "Jump_Full_Short",
  .ATTACK = "",
  .HIT    = "Hit_A",
  .DEATH  = "Death_A",
  .CHEER  = "Cheer",
}

Actor :: struct {
  model:    world.NodeHandle,
  scene:    gltf.Scene,
  rig:      gltf.RigHandle,
  animator: anim.Animator,
  layers:   [Clip]anim.LayerHandle,
  clip:     Clip,
}

Player :: struct {
  using actor: Actor,
  node:        world.NodeHandle,
  body:        physics.BodyHandle,
  health:      f32,
  strike:      f32,
  facing:      f32,
  buffs:       [Power]f32,
}

Enemy :: struct {
  using actor: Actor,
  kind:        EnemyKind,
  agent:       crowd.AgentHandle,
  health:      f32,
  cooldown:    f32,
  strike:      f32,
  repath:      f32,
  dying:       f32,
}

Pickup :: struct {
  node:  world.NodeHandle,
  power: Power,
  base:  [3]f32,
}

Projectile :: struct {
  node:     world.NodeHandle,
  velocity: [3]f32,
  damage:   f32,
  life:     f32,
}

Burst :: struct {
  node: world.NodeHandle,
  life: f32,
}

State :: enum {
  SELECT,
  PLAY,
  RESULT,
}

Panel :: struct {
  root, title, stats:  ui.NodeHandle,
  retry, next, heroes: ui.NodeHandle,
}

App :: struct {
  window:       platform.Platform,
  scene:        world.World,
  renderer:     render.Renderer,
  phys:         physics.World,
  input:        input.State,
  font:         font.Font,
  gui:          ui.UI,
  panel:        Panel,
  orbit:        render.Orbit,
  textures:     [Effect]render.TextureHandle,
  emitters:     [Effect]render.EmitterHandle,
  arrow:        render.MeshAttachment,
  fireball:     render.MeshAttachment,
  state:        State,
  hero:         int,
  level:        int,
  score:        int,
  won:          bool,
  result_timer: f32,
  lineup:       [len(HEROES)]Actor,
  spotlight:    world.NodeHandle,
  player:       Player,
  feet:         [3]f32,
  enemies:      [dynamic]Enemy,
  pickups:      [dynamic]Pickup,
  projectiles:  [dynamic]Projectile,
  bursts:       [dynamic]Burst,
  props:        [dynamic]gltf.Scene,
  navmesh:      nav.NavMesh,
  crowd:        crowd.Crowd,
}

Status :: enum {
  FAILURE,
  SUCCESS,
  RUNNING,
}

Leaf :: proc(app: ^App, e: ^Enemy) -> Status
Sequence :: distinct []Behavior
Selector :: distinct []Behavior
Behavior :: union {
  Leaf,
  Sequence,
  Selector,
}

MELEE := Behavior(Selector{
  Sequence{is_dead, die},
  Sequence{in_range, attack},
  Sequence{sees_player, chase},
  patrol,
})

RANGED := Behavior(Selector{
  Sequence{is_dead, die},
  Sequence{too_close, retreat},
  Sequence{in_range, attack},
  Sequence{sees_player, chase},
  patrol,
})

BOSS := Behavior(Selector{
  Sequence{is_dead, die},
  Sequence{in_range, attack},
  Sequence{enraged, charge},
  chase,
})

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1280, 720, "Third Person") do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !font.init(&app.font, #load("../../assets/Outfit-Regular.ttf")) do return .FAIL
  for data, effect in EFFECT_TEXTURES {
    texture, ok := render.texture_create(&app.renderer, data)
    if !ok do return .FAIL
    app.textures[effect] = texture
  }
  render.setup(&app.renderer)
  ui.init(&app.gui)
  build_panel(app)
  build_select(app)
  return .READY
}

shutdown :: proc(app: ^App) {
  clear_scene(app)
  delete(app.enemies)
  delete(app.pickups)
  delete(app.projectiles)
  delete(app.bursts)
  delete(app.props)
  ui.shutdown(&app.gui)
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

clear_scene :: proc(app: ^App) {
  for &a in app.lineup do actor_destroy(app, &a)
  actor_destroy(app, &app.player)
  for &e in app.enemies do actor_destroy(app, &e)
  for &s in app.props do gltf.scene_destroy(&s, &app.scene, &app.renderer)
  clear(&app.enemies)
  clear(&app.pickups)
  clear(&app.projectiles)
  clear(&app.bursts)
  clear(&app.props)
  crowd.shutdown(&app.crowd)
  nav.destroy(&app.navmesh)
  world.teardown(&app.scene)
  physics.teardown(&app.phys)
  render.teardown(&app.renderer)
}

build_select :: proc(app: ^App) {
  clear_scene(app)
  app.state = .SELECT
  spawn_ground(app)
  spawn_sun(app)
  for hero, i in HEROES {
    app.lineup[i] = actor_create(app, hero.model, hero.attack, {f32(i) * 2.2 - 4.4, 0, 0})
    show_props(app, app.lineup[i], hero.props)
  }
  app.spotlight = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(app.spotlight.index), render.light_create(&app.renderer, render.make_point_light({1, 0.85, 0.5}, 40, 6)))
  actor_play(&app.lineup[app.hero], .CHEER)
  render.camera_look_at(render.main_camera(&app.renderer), {0, 3, 9}, {0, 1.2, 0})
}

build_level :: proc(app: ^App, level: int) {
  clear_scene(app)
  app.state = .PLAY
  app.level = level
  app.result_timer = 0
  ui.node(&app.gui, app.panel.root).hidden = true
  spawn_ground(app)
  spawn_sun(app)
  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  bake_shape(&builder, render.make_quad(), {}, {ARENA * 2, 1, ARENA * 2})
  for box in LEVELS[level].obstacles {
    node := world.spawn(&app.scene, box.center)
    render.attach(&app.renderer, render.SlotHandle(node.index), render.primitive(&app.renderer, .CUBE, .GRAY))
    world.scale(&app.scene, node, box.half_extents)
    physics.body_create(&app.phys, box.center, collider = physics.BoxCollider{half_extents = box.half_extents})
    bake_shape(&builder, render.make_cube(), box.center, box.half_extents, is_obstacle = true)
  }
  for side in 0 ..< 4 {
    angle := f32(side) * math.PI * 0.5
    center := ARENA * [3]f32{math.cos(angle), 0, math.sin(angle)}
    physics.body_create(&app.phys, center + {0, 2, 0}, collider = physics.BoxCollider{half_extents = {0.5 + abs(center.z), 2, 0.5 + abs(center.x)}})
  }
  data, baked := bake.build(&builder, allocator = context.temp_allocator)
  if !baked || !nav.init(&app.navmesh, data) || !crowd.init(&app.crowd, 16, 1.2, &app.navmesh) {
    log.error("Navigation mesh bake failed")
    return
  }
  for decor, i in DECOR {
    angle := f32(i) / len(DECOR) * math.TAU
    node := world.spawn(&app.scene, (ARENA - 1.2) * [3]f32{math.cos(angle), 0, math.sin(angle)})
    world.rotate(&app.scene, node, angle * 3)
    append(&app.props, gltf.scene_create(&app.scene, &app.renderer, decor, parent = node))
  }
  for &emitter, effect in app.emitters do emitter = render.emitter_create(&app.renderer, effect_emitter(app, effect))
  torch_light := render.light_create(&app.renderer, render.make_point_light({1, 0.55, 0.2}, 30, 9, cast_shadow = false))
  for corner in ([4][3]f32{{-1, 0, -1}, {1, 0, -1}, {1, 0, 1}, {-1, 0, 1}}) {
    torch := world.spawn(&app.scene, corner * (ARENA - 2) + {0, 0.2, 0})
    render.attach(&app.renderer, render.SlotHandle(torch.index), app.emitters[.FIRE])
    glow := world.spawn(&app.scene, {0, 1, 0}, parent = torch)
    render.attach(&app.renderer, render.SlotHandle(glow.index), torch_light)
  }
  arrow := gltf.scene_create(&app.scene, &app.renderer, ARROW_MODEL)
  arrow_mesh, _ := world.find(&app.scene, "Skeleton_Arrow", arrow.roots[0])
  app.arrow = render.attachment(&app.renderer, render.SlotHandle(arrow_mesh.index), render.MeshAttachment)
  world.set_visible(&app.scene, arrow.roots[0], false)
  append(&app.props, arrow)
  fire_material := render.material_create(&app.renderer, render.make_material(base_color_factor = {1, 0.4, 0.1, 1}, emissive_value = 6))
  app.fireball = {mesh = app.renderer.builtin_meshes[.SPHERE], material = fire_material}

  hero := HEROES[app.hero]
  start := [3]f32{0, BODY_HEIGHT / 2, 0}
  p := &app.player
  p.node = world.spawn(&app.scene, start)
  p.body = physics.body_create(&app.phys, start, collider = physics.CylinderCollider{radius = BODY_RADIUS, height = BODY_HEIGHT}, mass = 70, user = world.Handle(p.node))
  params := physics.body_params(&app.phys, p.body)
  params.enable_rotation = false
  params.friction = 0
  p.actor = actor_create(app, hero.model, hero.attack, {0, -BODY_HEIGHT / 2, 0}, parent = p.node)
  show_props(app, p.actor, hero.props)
  p.health = hero.health
  p.facing = math.PI
  p.buffs = {}
  p.strike = 0

  enemies := LEVELS[level].enemies
  for kind, i in enemies {
    angle := f32(i) / f32(len(enemies)) * math.TAU + 0.4
    spawn_enemy(app, kind, 10 * [3]f32{math.cos(angle), 0, math.sin(angle)})
  }
  powers := LEVELS[level].powers
  for power, i in powers {
    angle := f32(i) / f32(len(powers)) * math.TAU + 1.2
    base := 5.5 * [3]f32{math.cos(angle), 0, math.sin(angle)} + {0, 0.8, 0}
    node := world.spawn(&app.scene, base)
    append(&app.props, gltf.scene_create(&app.scene, &app.renderer, POWER_MODELS[power], parent = node))
    append(&app.pickups, Pickup{node = node, power = power, base = base})
  }
  render.camera_look_at(render.main_camera(&app.renderer), {0, 6, -10}, {0, 1.5, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1.5, 0})
}

spawn_ground :: proc(app: ^App) {
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, ARENA * 2)
  physics.body_create(&app.phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {ARENA, 0.5, ARENA}})
}

spawn_sun :: proc(app: ^App) {
  sun := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(sun.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.92, 0.85}, 2.5, shadow_radius = 25)))
  world.rotate(&app.scene, sun, math.PI * 0.3, linalg.VECTOR3F32_X_AXIS)
}

bake_shape :: proc(builder: ^bake.NavGeometryBuilder, shape: render.Geometry, center, scale: [3]f32, is_obstacle := false) {
  defer render.destroy(shape)
  positions := render.positions(shape, context.temp_allocator)
  for &p in positions do p *= scale
  bake.append_triangles(builder, positions, shape.indices, center, is_obstacle)
}

spawn_enemy :: proc(app: ^App, kind: EnemyKind, position: [3]f32) {
  foe := FOES[kind]
  at := nav.nearest_point(&app.navmesh, position) or_else position
  params := crowd.DEFAULT_AGENT_PARAMS
  params.radius = 0.5 * foe.scale
  params.height = 2 * foe.scale
  params.max_speed = foe.speed
  agent := crowd.agent_create(&app.crowd, at, params) or_else {}
  e := Enemy{actor = actor_create(app, foe.model, foe.attack, at), kind = kind, agent = agent, health = foe.health}
  world.scale(&app.scene, e.model, foe.scale)
  for weapon, i in ([2][]u8{foe.right, foe.left}) {
    if weapon == nil do continue
    hand := world.find(&app.scene, "handslot.r" if i == 0 else "handslot.l", e.model) or_continue
    append(&app.props, gltf.scene_create(&app.scene, &app.renderer, weapon, parent = hand))
  }
  append(&app.enemies, e)
}

effect_emitter :: proc(app: ^App, effect: Effect) -> render.Emitter {
  texture := app.textures[effect]
  switch effect {
  case .HIT:
    return render.make_emitter(texture, 400, {0, 2, 0}, 3, {1, 0.9, 0.5, 1}, {1, 0.3, 0.1, 0}, 0.4, 0.2, 120, 20, 1)
  case .DEATH:
    return render.make_emitter(texture, 300, {0, 1.5, 0}, 1.5, {0.8, 0.8, 0.9, 0.8}, {0.3, 0.3, 0.4, 0}, 1.5, 0.6, 300, 500, -0.2)
  case .PICKUP:
    return render.make_emitter(texture, 400, {0, 3, 0}, 2, {0.5, 1, 0.6, 1}, {1, 1, 0.3, 0}, 0.8, 0.4, 150, 30, 0.3)
  case .MAGIC:
    return render.make_emitter(texture, 80, {0, 0.3, 0}, 0.3, {1, 0.6, 0.2, 1}, {1, 0.1, 0, 0}, 0.4, 0.1, 160, 40, 0)
  case .FIRE:
    return render.make_emitter(texture, 40, {0, 1.5, 0}, 0.3, {1, 0.7, 0.3, 1}, {1, 0.2, 0, 0}, 0.8, 0.2, 250, 60, -0.1)
  }
  return {}
}

burst :: proc(app: ^App, effect: Effect, position: [3]f32) {
  node := world.spawn(&app.scene, position)
  render.attach(&app.renderer, render.SlotHandle(node.index), app.emitters[effect])
  append(&app.bursts, Burst{node = node, life = BURST_TIME})
}

actor_create :: proc(app: ^App, model: []u8, attack: string, position: [3]f32, parent := world.NodeHandle{}) -> (a: Actor) {
  a.model = world.spawn(&app.scene, position, parent = parent)
  a.scene = gltf.scene_create(&app.scene, &app.renderer, model, parent = a.model)
  if len(a.scene.skinned) == 0 do return
  a.rig = a.scene.skinned[0].rig
  rig := &a.scene.rigs[a.rig]
  anim.animator_init(&a.animator, rig)
  for name, clip in CLIPS {
    mode: anim.PlayMode = .LOOP if clip == .IDLE || clip == .RUN else .ONCE
    clip_params := anim.ClipParams{clip = anim.clip_find(rig, attack if clip == .ATTACK else name), speed = 1, mode = mode}
    a.layers[clip] = anim.layer_create(&a.animator, rig, clip_params, weight = 1 if clip == .IDLE else 0)
  }
  return
}

actor_destroy :: proc(app: ^App, a: ^Actor) {
  anim.animator_destroy(&a.animator)
  gltf.scene_destroy(&a.scene, &app.scene, &app.renderer)
  world.destroy(&app.scene, a.model)
  a^ = {}
}

show_props :: proc(app: ^App, a: Actor, keep: []string) {
  for name in HERO_PROPS {
    node := world.find(&app.scene, name, a.model) or_continue
    shown := false
    for k in keep do shown ||= k == name
    world.set_visible(&app.scene, node, shown)
  }
}

actor_play :: proc(a: ^Actor, clip: Clip) {
  if clip == a.clip && (clip == .IDLE || clip == .RUN) do return
  anim.layer_fade(&a.animator, a.layers[a.clip], 0, CROSS_FADE)
  anim.layer_fade(&a.animator, a.layers[clip], 1, CROSS_FADE)
  anim.clip_seek(&a.animator, a.layers[clip], 0)
  a.clip = clip
}

actor_busy :: proc(a: ^Actor) -> bool {
  if a.clip == .IDLE || a.clip == .RUN do return false
  return a.clip == .DEATH || !anim.clip_done(&a.animator, a.layers[a.clip])
}

actor_move :: proc(a: ^Actor, moving: bool) {
  if !actor_busy(a) do actor_play(a, .RUN if moving else .IDLE)
}

actor_update :: proc(app: ^App, a: ^Actor, dt: f32) {
  if len(a.scene.skinned) == 0 do return
  anim.animator_update(&a.animator, &a.scene.rigs[a.rig], dt)
  gltf.pose_joints(&a.scene, &app.scene, a.rig, &a.animator)
}

actor_stage :: proc(app: ^App, a: ^Actor) {
  for s in a.scene.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), a.animator.palette)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  switch app.state {
  case .SELECT:
    update_select(app, dt)
  case .PLAY:
    update_play(app, dt)
  case .RESULT:
    update_result(app, dt)
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for &a in app.lineup do actor_stage(app, &a)
  actor_stage(app, &app.player)
  for &e in app.enemies do actor_stage(app, &e)
  render.update(&app.renderer, dt)
}

update_select :: proc(app: ^App, dt: f32) {
  step := int(input.key_pressed(&app.input, .D) || input.key_pressed(&app.input, .RIGHT)) - int(input.key_pressed(&app.input, .A) || input.key_pressed(&app.input, .LEFT))
  if step != 0 {
    actor_play(&app.lineup[app.hero], .IDLE)
    app.hero = (app.hero + step + len(HEROES)) % len(HEROES)
    actor_play(&app.lineup[app.hero], .CHEER)
  }
  world.translate(&app.scene, app.spotlight, f32(app.hero) * 2.2 - 4.4, 3, 1.5)
  for &a in app.lineup {
    actor_move(&a, false)
    actor_update(app, &a, dt)
  }
  if input.key_pressed(&app.input, .ENTER) || input.key_pressed(&app.input, .SPACE) {
    app.score = 0
    build_level(app, 0)
  }
}

update_play :: proc(app: ^App, dt: f32) {
  drag := app.input.mouse_delta if input.mouse_down(&app.input, .RIGHT) else 0
  render.orbit_drag(&app.orbit, drag, app.input.scroll.y, min_distance = 4, max_distance = 20)
  update_player(app, dt)
  physics.step(&app.phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  app.feet = physics.body(&app.phys, app.player.body).position - {0, BODY_HEIGHT / 2, 0}
  crowd.update(&app.crowd, dt)
  update_enemies(app, dt)
  update_projectiles(app, dt)
  update_pickups(app, dt)
  update_bursts(app, dt)
  app.orbit.target = app.feet + {0, 1.8, 0}
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if app.result_timer == 0 && len(app.enemies) == 0 && app.player.health > 0 {
    actor_play(&app.player, .CHEER)
    finish(app, true)
  }
  if app.result_timer > 0 {
    app.result_timer -= dt
    if app.result_timer <= 0 do show_result(app)
  }
}

update_player :: proc(app: ^App, dt: f32) {
  p := &app.player
  hero := HEROES[app.hero]
  for &b in p.buffs do b = max(b - dt, 0)
  alive := p.health > 0
  grounded := on_ground(app)
  move := move_direction(app) if alive else 0
  jump := false
  if alive && grounded && !actor_busy(p) {
    if input.mouse_pressed(&app.input, .LEFT) {
      actor_play(p, .ATTACK)
      p.strike = 0.35
    } else if input.key_pressed(&app.input, .SPACE) {
      actor_play(p, .JUMP)
      jump = true
    }
  }
  if alive do actor_move(p, linalg.length(move) > 0)
  if p.strike > 0 {
    p.strike -= dt
    if p.strike <= 0 do player_strike(app, hero.damage * (2 if p.buffs[.STRENGTH] > 0 else 1))
  }
  speed := hero.speed * (1.6 if p.buffs[.SPEED] > 0 else 1)
  velocity := move * speed if p.clip != .ATTACK else 0
  vertical := JUMP_SPEED if jump else physics.body(&app.phys, p.body).velocity.y
  physics.set_velocity(&app.phys, p.body, {velocity.x, vertical, velocity.z})
  if linalg.length(move) > 0 do p.facing = math.atan2(move.x, move.z)
  world.rotate(&app.scene, p.model, p.facing)
  actor_update(app, p, dt)
}

move_direction :: proc(app: ^App) -> [3]f32 {
  cam := render.main_camera(&app.renderer)
  forward := render.camera_forward(cam) * {1, 0, 1}
  right := render.camera_right(cam) * {1, 0, 1}
  return linalg.normalize0(forward * input.axis(&app.input, .S, .W) + right * input.axis(&app.input, .A, .D))
}

on_ground :: proc(app: ^App) -> bool {
  feet := physics.body(&app.phys, app.player.body).position - {0, BODY_HEIGHT / 2 + 0.01, 0}
  return physics.raycast(&app.phys, geometry.Ray{origin = feet, direction = {0, -1, 0}}, 0.1, first_hit = true).hit
}

player_strike :: proc(app: ^App, damage: f32) {
  forward := [2]f32{math.sin(app.player.facing), math.cos(app.player.facing)}
  for &e in app.enemies {
    if e.health <= 0 do continue
    to := enemy_position(app, &e).xz - app.feet.xz
    reach := REACH + 0.5 * FOES[e.kind].scale
    if linalg.length(to) < reach && linalg.dot(linalg.normalize0(to), forward) > 0.2 do hurt_enemy(app, &e, damage)
  }
}

hurt_enemy :: proc(app: ^App, e: ^Enemy, damage: f32) {
  e.health -= damage
  burst(app, .HIT, enemy_position(app, e) + {0, 1.2, 0})
  if e.health > 0 {
    actor_play(e, .HIT)
    return
  }
  app.score += FOES[e.kind].score
  burst(app, .DEATH, enemy_position(app, e) + {0, 0.5, 0})
}

hurt_player :: proc(app: ^App, damage: f32) {
  p := &app.player
  if p.health <= 0 || p.buffs[.SHIELD] > 0 do return
  p.health -= damage
  burst(app, .HIT, app.feet + {0, 1.4, 0})
  if p.health > 0 {
    if !actor_busy(p) do actor_play(p, .HIT)
    return
  }
  actor_play(p, .DEATH)
  finish(app, false)
}

finish :: proc(app: ^App, won: bool) {
  app.won = won
  app.result_timer = RESULT_DELAY
}

enemy_position :: proc(app: ^App, e: ^Enemy) -> [3]f32 {
  return crowd.agent(&app.crowd, e.agent).position
}

enemy_distance :: proc(app: ^App, e: ^Enemy) -> f32 {
  return linalg.length(enemy_position(app, e).xz - app.feet.xz)
}

update_enemies :: proc(app: ^App, dt: f32) {
  for i := len(app.enemies) - 1; i >= 0; i -= 1 {
    e := &app.enemies[i]
    e.cooldown -= dt
    e.repath -= dt
    if e.health <= 0 do e.dying += dt
    if app.player.health > 0 || e.health <= 0 do tick(brain(e.kind), app, e)
    agent := crowd.agent(&app.crowd, e.agent)
    world.translate(&app.scene, e.model, agent.position)
    if e.health > 0 {
      to := app.feet - agent.position if e.clip == .ATTACK || linalg.length(agent.velocity.xz) < 0.3 else agent.velocity
      world.rotate(&app.scene, e.model, math.atan2(to.x, to.z))
    }
    actor_move(e, linalg.length(agent.velocity.xz) > 0.3)
    if e.strike > 0 {
      e.strike -= dt
      if e.strike <= 0 && e.health > 0 do enemy_strike(app, e)
    }
    actor_update(app, e, dt)
    if e.dying > DESPAWN_TIME {
      crowd.agent_destroy(&app.crowd, e.agent)
      actor_destroy(app, e)
      unordered_remove(&app.enemies, i)
    }
  }
}

enemy_strike :: proc(app: ^App, e: ^Enemy) {
  foe := FOES[e.kind]
  if foe.shot == .NONE {
    if enemy_distance(app, e) <= foe.range + 0.5 do hurt_player(app, foe.damage)
    return
  }
  from := enemy_position(app, e) + {0, 1.4, 0}
  direction := linalg.normalize0(app.feet + {0, 1.2, 0} - from)
  node := world.spawn(&app.scene, from)
  world.rotate(&app.scene, node, linalg.quaternion_between_two_vector3([3]f32{0, 1, 0}, direction))
  if foe.shot == .ARROW {
    render.attach(&app.renderer, render.SlotHandle(node.index), app.arrow)
  } else {
    render.attach(&app.renderer, render.SlotHandle(node.index), app.fireball)
    world.scale(&app.scene, node, 0.25)
    trail := world.spawn(&app.scene, parent = node)
    render.attach(&app.renderer, render.SlotHandle(trail.index), app.emitters[.MAGIC])
  }
  append(&app.projectiles, Projectile{node = node, velocity = direction * 12, damage = foe.damage, life = 2})
}

brain :: proc(kind: EnemyKind) -> Behavior {
  switch kind {
  case .ROGUE, .MAGE:
    return RANGED
  case .BOSS:
    return BOSS
  case .MINION, .WARRIOR:
  }
  return MELEE
}

tick :: proc(b: Behavior, app: ^App, e: ^Enemy) -> Status {
  switch node in b {
  case Leaf:
    return node(app, e)
  case Sequence:
    for child in node do if status := tick(child, app, e); status != .SUCCESS do return status
    return .SUCCESS
  case Selector:
    for child in node do if status := tick(child, app, e); status != .FAILURE do return status
    return .FAILURE
  }
  return .FAILURE
}

is_dead :: proc(app: ^App, e: ^Enemy) -> Status {
  return .SUCCESS if e.health <= 0 else .FAILURE
}

die :: proc(app: ^App, e: ^Enemy) -> Status {
  if e.clip != .DEATH {
    actor_play(e, .DEATH)
    halt(app, e)
  }
  return .RUNNING
}

in_range :: proc(app: ^App, e: ^Enemy) -> Status {
  return .SUCCESS if enemy_distance(app, e) <= FOES[e.kind].range else .FAILURE
}

attack :: proc(app: ^App, e: ^Enemy) -> Status {
  halt(app, e)
  if e.cooldown > 0 do return .RUNNING
  actor_play(e, .ATTACK)
  e.cooldown = FOES[e.kind].cooldown
  e.strike = FOES[e.kind].windup
  return .SUCCESS
}

sees_player :: proc(app: ^App, e: ^Enemy) -> Status {
  return .SUCCESS if enemy_distance(app, e) <= SIGHT else .FAILURE
}

chase :: proc(app: ^App, e: ^Enemy) -> Status {
  if e.repath <= 0 {
    e.repath = 0.5
    crowd.move_to(&app.crowd, e.agent, app.feet)
  }
  return .RUNNING
}

too_close :: proc(app: ^App, e: ^Enemy) -> Status {
  return .SUCCESS if enemy_distance(app, e) < FOES[e.kind].range * 0.4 else .FAILURE
}

retreat :: proc(app: ^App, e: ^Enemy) -> Status {
  if e.repath <= 0 {
    e.repath = 0.5
    position := enemy_position(app, e)
    crowd.move_to(&app.crowd, e.agent, position + linalg.normalize0(position - app.feet) * 4)
  }
  return .RUNNING
}

patrol :: proc(app: ^App, e: ^Enemy) -> Status {
  if e.repath <= 0 {
    e.repath = 3
    crowd.move_to(&app.crowd, e.agent, {rand.float32_range(-ARENA, ARENA), 0, rand.float32_range(-ARENA, ARENA)} * 0.7)
  }
  return .RUNNING
}

enraged :: proc(app: ^App, e: ^Enemy) -> Status {
  return .SUCCESS if e.health < FOES[e.kind].health * 0.5 else .FAILURE
}

charge :: proc(app: ^App, e: ^Enemy) -> Status {
  crowd.agent_params(&app.crowd, e.agent).max_speed = FOES[e.kind].speed * 1.8
  return chase(app, e)
}

halt :: proc(app: ^App, e: ^Enemy) {
  crowd.move_to(&app.crowd, e.agent, enemy_position(app, e))
}

update_projectiles :: proc(app: ^App, dt: f32) {
  for i := len(app.projectiles) - 1; i >= 0; i -= 1 {
    shot := &app.projectiles[i]
    shot.life -= dt
    world.translate_by(&app.scene, shot.node, shot.velocity * dt)
    position := world.world_matrix(&app.scene, shot.node)[3].xyz
    hit := linalg.length(position - (app.feet + {0, 1.2, 0})) < 0.8
    if hit do hurt_player(app, shot.damage)
    if hit || shot.life <= 0 {
      world.destroy(&app.scene, shot.node)
      unordered_remove(&app.projectiles, i)
    }
  }
}

update_pickups :: proc(app: ^App, dt: f32) {
  for i := len(app.pickups) - 1; i >= 0; i -= 1 {
    pickup := &app.pickups[i]
    world.rotate_by(&app.scene, pickup.node, dt * 2)
    world.translate(&app.scene, pickup.node, pickup.base + {0, 0.2 * math.sin(f32(app.renderer.time) * 3), 0})
    if app.player.health <= 0 || linalg.length(pickup.base.xz - app.feet.xz) > 1.2 do continue
    if pickup.power == .HEAL {
      app.player.health = min(app.player.health + 50, HEROES[app.hero].health)
    } else {
      app.player.buffs[pickup.power] = BUFF_TIME
    }
    burst(app, .PICKUP, pickup.base)
    world.destroy(&app.scene, pickup.node)
    unordered_remove(&app.pickups, i)
  }
}

update_bursts :: proc(app: ^App, dt: f32) {
  for i := len(app.bursts) - 1; i >= 0; i -= 1 {
    app.bursts[i].life -= dt
    if app.bursts[i].life > 0 do continue
    world.destroy(&app.scene, app.bursts[i].node)
    unordered_remove(&app.bursts, i)
  }
}

build_panel :: proc(app: ^App) {
  gui := &app.gui
  p := &app.panel
  p.root = ui.node_create(gui, {position = .ABSOLUTE, anchor = {0.5, 0.5}, direction = .COLUMN, padding = {28, 24, 28, 24}, gap = 14, align = {.CENTER, .CENTER}, hidden = true})
  p.title = ui.node_create(gui, {parent = p.root, text = "Victory", font_size = 40})
  p.stats = ui.node_create(gui, {parent = p.root, font_size = 20})
  row := ui.node_create(gui, {parent = p.root, gap = 12})
  button :: proc(gui: ^ui.UI, parent: ui.NodeHandle, label: string) -> ui.NodeHandle {
    b := ui.node_create(gui, {parent = parent, size = {{.FIXED, 150}, {.FIXED, 44}}, align = {.CENTER, .CENTER}, interactive = true})
    ui.node_create(gui, {parent = b, text = label, font_size = 20})
    return b
  }
  p.retry = button(gui, row, "Retry")
  p.next = button(gui, row, "Next level")
  p.heroes = button(gui, row, "Change hero")
}

show_result :: proc(app: ^App) {
  app.state = .RESULT
  last := app.level == len(LEVELS) - 1
  ui.set_text(&app.gui, app.panel.title, ("Victory!" if !last else "The crypt is cleared!") if app.won else "Defeated")
  ui.set_text(&app.gui, app.panel.stats, fmt.tprintf("Level %d   Score %d", app.level + 1, app.score))
  ui.node(&app.gui, app.panel.next).hidden = !app.won || last
  ui.node(&app.gui, app.panel.root).hidden = false
}

update_result :: proc(app: ^App, dt: f32) {
  size := platform.framebuffer_size(&app.window)
  ui.layout(&app.gui, {size = {f32(size.x), f32(size.y)} / platform.dpi_scale(&app.window)}, &app.font)
  ui.update_input(&app.gui, &app.input)
  actor_update(app, &app.player, dt)
  for &e in app.enemies do actor_update(app, &e, dt)
  switch {
  case ui.clicked(&app.gui, app.panel.retry):
    if !app.won do app.score = 0
    build_level(app, app.level)
  case ui.clicked(&app.gui, app.panel.next):
    build_level(app, app.level + 1)
  case ui.clicked(&app.gui, app.panel.heroes):
    ui.node(&app.gui, app.panel.root).hidden = true
    build_select(app)
  }
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  commands := make([dynamic]render.RenderCommand, context.temp_allocator)
  size := platform.framebuffer_size(&app.window)
  screen := [2]f32{f32(size.x), f32(size.y)} / platform.dpi_scale(&app.window)
  if app.state == .SELECT {
    hero := HEROES[app.hero]
    text(&commands, "Choose your hero", {40, 36}, 40)
    text(&commands, fmt.tprintf("%s   health %.0f   speed %.1f   damage %.0f", hero.name, hero.health, hero.speed, hero.damage), {40, 90}, 24)
    text(&commands, "A / D choose     Enter start", {40, 126}, 20, {200, 200, 210, 255})
    text(&commands, CREDITS, {40, screen.y - 40}, 16, {200, 200, 210, 255})
  } else {
    hud(app, &commands)
  }
  if app.state == .RESULT {
    for h, z in app.gui.draw_order {
      r := ui.rect(&app.gui, h)
      n := ui.node(&app.gui, h)
      if h == app.panel.root do append(&commands, render.RenderCommand{shape = render.DrawQuadCommand{position = r.pos, size = r.size, color = {20, 20, 30, 230}}, z_order = i32(z) + 100})
      if n.interactive {
        color: [4]u8 = {200, 90, 60, 255} if ui.hovered(&app.gui, h) else {150, 60, 45, 255}
        append(&commands, render.RenderCommand{shape = render.DrawQuadCommand{position = r.pos, size = r.size, color = color}, z_order = i32(z) + 100})
      }
      for line in ui.lines(&app.gui, h) {
        label := render.DrawTextCommand{text = n.text[line.start:line.end], position = line.pos, size = n.font_size, color = 255}
        append(&commands, render.RenderCommand{shape = label, z_order = i32(z) + 100})
      }
    }
  }
  render.stage_overlay(&app.renderer, commands[:], &app.font)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

hud :: proc(app: ^App, commands: ^[dynamic]render.RenderCommand) {
  p := &app.player
  bar(commands, {40, 36}, {300, 22}, p.health / HEROES[app.hero].health, {220, 50, 50, 255})
  text(commands, fmt.tprintf("Level %d / %d    Score %d", app.level + 1, len(LEVELS), app.score), {40, 68}, 22)
  y: f32 = 100
  for time, power in p.buffs {
    if time <= 0 do continue
    text(commands, fmt.tprintf("%v %.0fs", power, time), {40, y}, 18, {140, 230, 140, 255})
    y += 24
  }
  text(commands, "WASD run   Space jump   Left click attack   Right drag look", {40, y + 8}, 16, {200, 200, 210, 255})
  for &e in app.enemies {
    if e.health <= 0 do continue
    head := enemy_position(app, &e) + {0, 2.4 * FOES[e.kind].scale, 0}
    point := render.world_to_screen(&app.renderer, head) or_continue
    bar(commands, point - {30, 0}, {60, 7}, e.health / FOES[e.kind].health, {230, 200, 60, 255})
  }
}

text :: proc(commands: ^[dynamic]render.RenderCommand, s: string, position: [2]f32, size: f32, color: [4]u8 = 255) {
  append(commands, render.RenderCommand{shape = render.DrawTextCommand{text = s, position = position, size = size, color = color}})
}

bar :: proc(commands: ^[dynamic]render.RenderCommand, position, size: [2]f32, fraction: f32, color: [4]u8) {
  append(commands, render.RenderCommand{shape = render.DrawQuadCommand{position = position, size = size, color = {0, 0, 0, 160}}})
  append(commands, render.RenderCommand{shape = render.DrawQuadCommand{position = position + 2, size = {(size.x - 4) * clamp(fraction, 0, 1), size.y - 4}, color = color}})
}
