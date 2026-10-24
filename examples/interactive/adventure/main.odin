// Simple third-person adventure game
// Characters and props: KayKit Character Pack Adventurers 1.0 and Skeletons 1.0 by Kay Lousberg (www.kaylousberg.com)
// Particle textures: Kenney Particle Pack (www.kenney.nl)
package main

import "mjolnir"
import "mjolnir/animation"
import bt "mjolnir/behavior_tree"
import "mjolnir/fsm"
import "mjolnir/font"
import "mjolnir/geometry"
import "mjolnir/gltf"
import "mjolnir/input"
import nav "mjolnir/navigation"
import "mjolnir/navigation/bake"
import "mjolnir/physics"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/ui"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

DEBUG :: #config(DEBUG, false)
CREDITS :: "Characters & props: KayKit by Kay Lousberg (CC0)   Particles: Kenney (CC0)"

ARENA :: 14
BODY_RADIUS :: 0.5
BODY_HALF_HEIGHT :: 1.2
JUMP_SPEED :: 8
REACH :: 2.2
SIGHT :: 16
BUFF_TIME :: 10
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
  shot:   Shot,
}

HEROES := [?]Hero {
  {"Knight", #load("assets/kaykit_adventurers/Knight.glb"), {"1H_Sword", "Round_Shield"}, "1H_Melee_Attack_Chop", 140, 5, 22, .NONE},
  {"Barbarian", #load("assets/kaykit_adventurers/Barbarian.glb"), {"1H_Axe", "Barbarian_Round_Shield"}, "1H_Melee_Attack_Slice_Diagonal", 170, 4.5, 26, .NONE},
  {"Mage", #load("assets/kaykit_adventurers/Mage.glb"), {"2H_Staff"}, "Spellcast_Shoot", 100, 5.5, 34, .FIREBALL},
  {"Rogue", #load("assets/kaykit_adventurers/Rogue.glb"), {"Knife", "Knife_Offhand"}, "Dualwield_Melee_Attack_Stab", 110, 6.5, 24, .NONE},
  {"Rogue_Hooded", #load("assets/kaykit_adventurers/Rogue_Hooded.glb"), {"Knife", "Knife_Offhand"}, "Dualwield_Melee_Attack_Slice", 110, 6.5, 24, .NONE},
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
    model = #load("assets/kaykit_skeletons/Skeleton_Minion.glb"),
    right = #load("assets/kaykit_skeletons/Skeleton_Blade.glb"),
    left = #load("assets/kaykit_skeletons/Skeleton_Shield_Small_A.glb"),
    attack = "1H_Melee_Attack_Chop", health = 40, speed = 2.6, damage = 10, range = 1.8, cooldown = 1.4, windup = 0.45, scale = 1, score = 10,
  },
  .ROGUE = {
    model = #load("assets/kaykit_skeletons/Skeleton_Rogue.glb"),
    right = #load("assets/kaykit_skeletons/Skeleton_Crossbow.glb"),
    attack = "1H_Ranged_Shoot", shot = .ARROW, health = 30, speed = 3.2, damage = 8, range = 9, cooldown = 2, windup = 0.3, scale = 1, score = 15,
  },
  .MAGE = {
    model = #load("assets/kaykit_skeletons/Skeleton_Mage.glb"),
    right = #load("assets/kaykit_skeletons/Skeleton_Staff.glb"),
    attack = "Spellcast_Shoot", shot = .FIREBALL, health = 30, speed = 2.4, damage = 14, range = 10, cooldown = 2.6, windup = 0.5, scale = 1, score = 20,
  },
  .WARRIOR = {
    model = #load("assets/kaykit_skeletons/Skeleton_Warrior.glb"),
    right = #load("assets/kaykit_skeletons/Skeleton_Axe.glb"),
    left = #load("assets/kaykit_skeletons/Skeleton_Shield_Large_A.glb"),
    attack = "1H_Melee_Attack_Slice_Diagonal", health = 90, speed = 2.2, damage = 18, range = 2, cooldown = 1.8, windup = 0.5, scale = 1.15, score = 30,
  },
  .BOSS = {
    model = #load("assets/kaykit_skeletons/Skeleton_Warrior.glb"),
    right = #load("assets/kaykit_skeletons/Skeleton_Axe.glb"),
    left = #load("assets/kaykit_skeletons/Skeleton_Shield_Large_B.glb"),
    attack = "2H_Melee_Attack_Spin", health = 320, speed = 2.4, damage = 26, range = 3, cooldown = 1.6, windup = 0.6, scale = 1.8, score = 200,
  },
}

ARROW_MODEL :: #load("assets/kaykit_skeletons/Skeleton_Arrow.glb")

Power :: enum {
  HEAL,
  STRENGTH,
  SPEED,
  SHIELD,
}

POWER_MODELS := [Power][]u8 {
  .HEAL     = #load("assets/kaykit_adventurers/mug_full.glb"),
  .STRENGTH = #load("assets/kaykit_adventurers/spellbook_open.glb"),
  .SPEED    = #load("assets/kaykit_adventurers/smokebomb.glb"),
  .SHIELD   = #load("assets/kaykit_adventurers/shield_badge_color.glb"),
}

DECOR := [?][]u8 {
  #load("assets/kaykit_adventurers/arrow.glb"),
  #load("assets/kaykit_adventurers/arrow_bundle.glb"),
  #load("assets/kaykit_adventurers/axe_1handed.glb"),
  #load("assets/kaykit_adventurers/axe_2handed.glb"),
  #load("assets/kaykit_adventurers/crossbow_1handed.glb"),
  #load("assets/kaykit_adventurers/crossbow_2handed.glb"),
  #load("assets/kaykit_adventurers/dagger.glb"),
  #load("assets/kaykit_adventurers/mug_empty.glb"),
  #load("assets/kaykit_adventurers/quiver.glb"),
  #load("assets/kaykit_adventurers/shield_badge.glb"),
  #load("assets/kaykit_adventurers/shield_round.glb"),
  #load("assets/kaykit_adventurers/shield_round_barbarian.glb"),
  #load("assets/kaykit_adventurers/shield_round_color.glb"),
  #load("assets/kaykit_adventurers/shield_spikes.glb"),
  #load("assets/kaykit_adventurers/shield_spikes_color.glb"),
  #load("assets/kaykit_adventurers/shield_square.glb"),
  #load("assets/kaykit_adventurers/shield_square_color.glb"),
  #load("assets/kaykit_adventurers/spellbook_closed.glb"),
  #load("assets/kaykit_adventurers/staff.glb"),
  #load("assets/kaykit_adventurers/sword_1handed.glb"),
  #load("assets/kaykit_adventurers/sword_2handed.glb"),
  #load("assets/kaykit_adventurers/sword_2handed_color.glb"),
  #load("assets/kaykit_adventurers/wand.glb"),
  #load("assets/kaykit_skeletons/Skeleton_Arrow_Broken.glb"),
  #load("assets/kaykit_skeletons/Skeleton_Arrow_Broken_Half.glb"),
  #load("assets/kaykit_skeletons/Skeleton_Arrow_Half.glb"),
  #load("assets/kaykit_skeletons/Skeleton_Quiver.glb"),
  #load("assets/kaykit_skeletons/Skeleton_Shield_Small_B.glb"),
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
  .HIT    = #load("assets/particles/star_04.png"),
  .DEATH  = #load("assets/particles/smoke_04.png"),
  .PICKUP = #load("assets/particles/star_06.png"),
  .MAGIC  = #load("assets/particles/light_02.png"),
  .FIRE   = #load("assets/particles/flame_02.png"),
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
  chest:    world.NodeHandle,
  instance: gltf.Instance,
  animator: ^animation.Animator,
  layers:   [Clip]animation.LayerHandle,
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
  agent:       nav.AgentHandle,
  health:      f32,
  cooldown:    f32,
  strike:      f32,
  repath:      f32,
  dying:       f32,
  trace:       [dynamic]bt.Step,
}

TRACE_COLORS := [bt.Status][4]u8 {
  .FAILURE = {170, 170, 180, 255},
  .SUCCESS = {120, 230, 120, 255},
  .RUNNING = {250, 210, 80, 255},
}


Pickup :: struct {
  node:     world.NodeHandle,
  instance: gltf.Instance,
  power:    Power,
  base:     [3]f32,
}

Projectile :: struct {
  friendly: bool,
  node:     world.NodeHandle,
  instance: gltf.Instance,
  position: [3]f32,
  velocity: [3]f32,
  damage:   f32,
  life:     f32,
}

Screen :: enum {
  SELECT,
  LEVEL_1,
  LEVEL_2,
  LEVEL_3,
  RESULT,
}

SCREENS := [Screen]fsm.State(App, Screen) {
  .SELECT  = {enter = enter_select, update = update_select},
  .LEVEL_1 = {enter = enter_level, update = update_level},
  .LEVEL_2 = {enter = enter_level, update = update_level},
  .LEVEL_3 = {enter = enter_level, update = update_level},
  .RESULT  = {enter = enter_result, update = update_result, exit = exit_result},
}

#assert(len(LEVELS) == int(Screen.LEVEL_3) - int(Screen.LEVEL_1) + 1)

Panel :: struct {
  root, title, stats:  ui.NodeHandle,
  retry, next, heroes: ui.NodeHandle,
}

App :: struct {
  platform:     platform.Platform,
  scene:        world.World,
  renderer:     render.Renderer,
  phys:         physics.World,
  input:        input.State,
  font:         font.Font,
  gui:          ui.UI,
  panel:        Panel,
  orbit:        render.Orbit,
  show_debug:   bool,
  bodies:       [dynamic]physics.BodyHandle,
  textures:     [Effect]render.TextureHandle,
  emitters:     [Effect]render.EmitterHandle,
  heroes:       [len(HEROES)]gltf.Model,
  foes:         [EnemyKind]gltf.Model,
  weapons:      [EnemyKind][2]gltf.Model,
  powers:       [Power]gltf.Model,
  decor:        [len(DECOR)]gltf.Model,
  arrow:        gltf.Model,
  fireball:     render.MeshAttachment,
  screen:       fsm.Machine(Screen),
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
  props:        [dynamic]gltf.Instance,
  navmesh:      nav.NavMesh,
  crowd:        nav.Crowd,
}

Mob :: struct {
  app:   ^App,
  enemy: ^Enemy,
}

Condition :: bt.Condition(Mob)
Action :: bt.Action(Mob)
Sequence :: bt.Sequence(Mob)
Behavior :: bt.Behavior(Mob)

MELEE := Behavior(Sequence{{
  Condition{"is_dead", is_dead, {Action{"die", die}}},
  Condition{"in_range", in_range, {Action{"attack", attack}}},
  Condition{"sees_player", sees_player, {Action{"chase", chase}}},
  Action{"patrol", patrol},
}})

RANGED := Behavior(Sequence{{
  Condition{"is_dead", is_dead, {Action{"die", die}}},
  Condition{"too_close", too_close, {Action{"retreat", retreat}}},
  Condition{"in_range", in_range, {Action{"attack", attack}}},
  Condition{"sees_player", sees_player, {Action{"chase", chase}}},
  Action{"patrol", patrol},
}})

BOSS := Behavior(Sequence{{
  Condition{"is_dead", is_dead, {Action{"die", die}}},
  Condition{"in_range", in_range, {Action{"attack", attack}}},
  Condition{"enraged", enraged, {Action{"charge", charge}}},
  Action{"chase", chase},
}})

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.show_debug = DEBUG
  if !platform.init(&app.platform, 1280, 720, "Third Person") do return
  if !render.init(&app.renderer, app.platform.window) do return
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
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  if !load_assets(app) do return .FAIL
  append(&app.renderer.effect_stack, render.OutlineEffect{thickness = 1.5}, render.CrossHatchEffect{hatch_offset_y = 5, lum_thresholds = {0.6, 0.3, 0.15, 0.07}})
  render.setup(&app.renderer)
  ui.init(&app.gui, {1280, 720})
  build_panel(app)
  fsm.start(&app.screen, SCREENS, app, .SELECT)
  return .READY
}

shutdown :: proc(app: ^App) {
  clear_scene(app)
  delete(app.enemies)
  delete(app.pickups)
  delete(app.projectiles)
  delete(app.props)
  delete(app.bodies)
  for &m in app.heroes do gltf.destroy(&m, &app.renderer)
  for &m in app.foes do gltf.destroy(&m, &app.renderer)
  for &pair in app.weapons do for &m in pair do gltf.destroy(&m, &app.renderer)
  for &m in app.powers do gltf.destroy(&m, &app.renderer)
  for &m in app.decor do gltf.destroy(&m, &app.renderer)
  gltf.destroy(&app.arrow, &app.renderer)
  ui.shutdown(&app.gui)
  font.destroy(&app.font)
  physics.shutdown(&app.phys)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

load_assets :: proc(app: ^App) -> bool {
  for data, effect in EFFECT_TEXTURES do app.textures[effect] = render.texture_create(&app.renderer, data) or_return
  for hero, i in HEROES do app.heroes[i] = gltf.model_create(&app.renderer, hero.model) or_return
  for foe, kind in FOES {
    app.foes[kind] = gltf.model_create(&app.renderer, foe.model) or_return
    if foe.right != nil do app.weapons[kind][0] = gltf.model_create(&app.renderer, foe.right) or_return
    if foe.left != nil do app.weapons[kind][1] = gltf.model_create(&app.renderer, foe.left) or_return
  }
  for data, power in POWER_MODELS do app.powers[power] = gltf.model_create(&app.renderer, data) or_return
  for data, i in DECOR do app.decor[i] = gltf.model_create(&app.renderer, data) or_return
  app.arrow = gltf.model_create(&app.renderer, ARROW_MODEL) or_return
  return true
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

clear_scene :: proc(app: ^App) {
  for &a in app.lineup do actor_destroy(app, &a)
  actor_destroy(app, &app.player)
  for &e in app.enemies {
    actor_destroy(app, &e)
    delete(e.trace)
  }
  for &i in app.props do gltf.destroy(&i, &app.scene)
  for &p in app.pickups do gltf.destroy(&p.instance, &app.scene)
  for &p in app.projectiles do gltf.destroy(&p.instance, &app.scene)
  clear(&app.enemies)
  clear(&app.pickups)
  clear(&app.projectiles)
  clear(&app.props)
  clear(&app.bodies)
  nav.crowd_shutdown(&app.crowd)
  nav.destroy(&app.navmesh)
  world.teardown(&app.scene)
  physics.teardown(&app.phys)
  render.teardown(&app.renderer)
}

enter_select :: proc(app: ^App) {
  clear_scene(app)
  spawn_ground(app)
  app.renderer.ibl_intensity = 0.1
  app.renderer.skybox_intensity = 0.05
  spawn_sun(app, 0.2)
  for hero, i in HEROES {
    app.lineup[i] = actor_create(app, &app.heroes[i], hero.attack, {f32(i) * 2.2 - 4.4, 0, 0})
    show_props(app, app.lineup[i], hero.props)
  }
  app.spotlight = world.spawn(&app.scene)
  world.rotate(&app.scene, app.spotlight, linalg.quaternion_between_two_vector3([3]f32{0, 0, -1}, linalg.normalize([3]f32{0, -4, -3})))
  render.attach(&app.renderer, render.SlotHandle(app.spotlight.index), render.light_create(&app.renderer, render.make_spot_light({1, 0.85, 0.6}, 500, 12, math.PI * 0.1)))
  actor_play(&app.lineup[app.hero], .CHEER)
  render.camera_look_at(render.main_camera(&app.renderer), {0, 3, 9}, {0, 1.2, 0})
}

level_screen :: proc(level: int) -> Screen {
  return Screen(int(Screen.LEVEL_1) + level)
}

enter_level :: proc(app: ^App) {
  clear_scene(app)
  level := int(app.screen.current) - int(Screen.LEVEL_1)
  app.level = level
  app.result_timer = 0
  spawn_ground(app)
  app.renderer.ibl_intensity = 1
  app.renderer.skybox_intensity = 1
  spawn_sun(app, 2.5)
  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  bake.append_box(&builder, {0, -0.5, 0}, {ARENA * 2, 0.5, ARENA * 2})
  for box in LEVELS[level].obstacles {
    node := world.spawn(&app.scene, box.center)
    render.attach(&app.renderer, render.SlotHandle(node.index), render.primitive(&app.renderer, .CUBE, .GRAY))
    world.scale(&app.scene, node, box.half_extents)
    append(&app.bodies, physics.body_create(&app.phys, box.center, collider = physics.BoxCollider{half_extents = box.half_extents}))
    bake.append_box(&builder, box.center, box.half_extents, is_obstacle = true)
  }
  for side in 0 ..< 4 {
    angle := f32(side) * math.PI * 0.5
    center := ARENA * [3]f32{math.cos(angle), 0, math.sin(angle)}
    append(&app.bodies, physics.body_create(&app.phys, center + {0, 2, 0}, collider = physics.BoxCollider{half_extents = {0.5 + abs(center.z), 2, 0.5 + abs(center.x)}}))
  }
  data, baked := bake.build(&builder, allocator = context.temp_allocator)
  if !baked || !nav.init(&app.navmesh, data) || !nav.crowd_init(&app.crowd, 16, 1.2, &app.navmesh) {
    log.error("Navigation mesh bake failed")
    return
  }
  for &decor, i in app.decor {
    angle := f32(i) / len(DECOR) * math.TAU
    node := world.spawn(&app.scene, (ARENA - 1.2) * [3]f32{math.cos(angle), 0, math.sin(angle)})
    world.rotate(&app.scene, node, angle * 3)
    append(&app.props, gltf.instance_create(&decor, &app.scene, &app.renderer, parent = node))
  }
  for &emitter, effect in app.emitters do emitter = render.emitter_create(&app.renderer, effect_emitter(app, effect))
  torch_light := render.light_create(&app.renderer, render.make_point_light({1, 0.55, 0.2}, 30, 9, cast_shadow = false))
  for corner in ([4][3]f32{{-1, 0, -1}, {1, 0, -1}, {1, 0, 1}, {-1, 0, 1}}) {
    torch := world.spawn(&app.scene, corner * (ARENA - 2) + {0, 0.2, 0})
    render.attach(&app.renderer, render.SlotHandle(torch.index), app.emitters[.FIRE])
    glow := world.spawn(&app.scene, {0, 1, 0}, parent = torch)
    render.attach(&app.renderer, render.SlotHandle(glow.index), torch_light)
  }
  fire_material := render.material_create(&app.renderer, render.make_material(base_color_factor = {1, 0.4, 0.1, 1}, emissive_value = 1.5))
  app.fireball = render.primitive(&app.renderer, .SPHERE, fire_material, cast_shadow = false)

  hero := HEROES[app.hero]
  start := [3]f32{0, BODY_HALF_HEIGHT, 0}
  p := &app.player
  p.node = world.spawn(&app.scene, start)
  p.body = physics.body_create(&app.phys, start, collider = physics.CylinderCollider{radius = BODY_RADIUS, half_height = BODY_HALF_HEIGHT}, mass = 70, user = world.Handle(p.node))
  append(&app.bodies, p.body)
  params := physics.body_params(&app.phys, p.body)
  params.enable_rotation = false
  params.friction = 0
  p.actor = actor_create(app, &app.heroes[app.hero], hero.attack, {0, -BODY_HALF_HEIGHT, 0}, parent = p.node)
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
    instance := gltf.instance_create(&app.powers[power], &app.scene, &app.renderer, parent = node)
    append(&app.pickups, Pickup{node = node, instance = instance, power = power, base = base})
  }
  app.orbit = render.make_orbit({0, 6, -10}, {0, 1.5, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
}

spawn_ground :: proc(app: ^App) {
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, ARENA * 2)
  append(&app.bodies, physics.body_create(&app.phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {ARENA, 0.5, ARENA}}))
}

spawn_sun :: proc(app: ^App, intensity: f32) {
  app.renderer.sun = {
    enabled         = true,
    cast_shadow     = true,
    color           = {1, 0.92, 0.85},
    intensity       = intensity,
    direction       = linalg.quaternion_mul_vector3(linalg.quaternion_angle_axis(-math.PI * 0.7, linalg.VECTOR3F32_X_AXIS), [3]f32{0, 0, -1}),
    shadow_distance = 25,
  }
}


spawn_enemy :: proc(app: ^App, kind: EnemyKind, position: [3]f32) {
  foe := FOES[kind]
  at := nav.nearest_point(&app.navmesh, position) or_else position
  params := nav.DEFAULT_AGENT_PARAMS
  params.radius = 0.5 * foe.scale
  params.height = 2 * foe.scale
  params.max_speed = foe.speed
  e := Enemy{actor = actor_create(app, &app.foes[kind], foe.attack, at), kind = kind, health = foe.health}
  e.agent = nav.agent_create(&app.crowd, at, params, user = world.Handle(e.model)) or_else {}
  world.scale(&app.scene, e.model, foe.scale)
  for &weapon, i in app.weapons[kind] {
    if len(weapon.nodes) == 0 do continue
    hand := world.find(&app.scene, "handslot.r" if i == 0 else "handslot.l", e.model) or_continue
    append(&app.props, gltf.instance_create(&weapon, &app.scene, &app.renderer, parent = hand))
  }
  append(&app.enemies, e)
}

effect_emitter :: proc(app: ^App, effect: Effect) -> render.Emitter {
  texture := app.textures[effect]
  switch effect {
  case .HIT:
    return render.make_emitter(texture, 0, {0, 2, 0}, 3, {1, 0.9, 0.5, 1}, {1, 0.3, 0.1, 0}, 0.4, 0.2, 120, 20, 1)
  case .DEATH:
    return render.make_emitter(texture, 0, {0, 1.5, 0}, 1.5, {0.8, 0.8, 0.9, 0.8}, {0.3, 0.3, 0.4, 0}, 1.5, 0.6, 300, 500, -0.2)
  case .PICKUP:
    return render.make_emitter(texture, 0, {0, 3, 0}, 2, {0.5, 1, 0.6, 1}, {1, 1, 0.3, 0}, 0.8, 0.4, 150, 30, 0.3)
  case .MAGIC:
    return render.make_emitter(texture, 200, {0, 0.3, 0}, 0.4, {1, 0.5, 0.1, 1}, {1, 0.1, 0, 0}, 0.5, 0.15, 240, 40, 0)
  case .FIRE:
    return render.make_emitter(texture, 40, {0, 1.5, 0}, 0.3, {1, 0.7, 0.3, 1}, {1, 0.2, 0, 0}, 0.8, 0.2, 250, 60, -0.1)
  }
  return {}
}


actor_create :: proc(app: ^App, model: ^gltf.Model, attack: string, position: [3]f32, parent := world.NodeHandle{}) -> (a: Actor) {
  a.model = world.spawn(&app.scene, position, parent = parent)
  a.instance = gltf.instance_create(model, &app.scene, &app.renderer, parent = a.model)
  a.chest = world.find(&app.scene, "chest", a.model) or_else a.model
  if len(a.instance.skinned) == 0 do return
  rig := &model.rigs[a.instance.skinned[0].rig]
  a.animator = &a.instance.animators[a.instance.skinned[0].rig]
  for name, clip in CLIPS {
    mode: animation.PlayMode = .LOOP if clip == .IDLE || clip == .RUN else .ONCE
    clip_params := animation.ClipParams{clip = animation.clip_find(rig, attack if clip == .ATTACK else name), speed = 1, mode = mode}
    a.layers[clip] = animation.layer_create(a.animator, rig, clip_params, weight = 1 if clip == .IDLE else 0)
  }
  return
}

actor_destroy :: proc(app: ^App, a: ^Actor) {
  gltf.destroy(&a.instance, &app.scene)
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
  animation.layer_fade(a.animator, a.layers[a.clip], 0, CROSS_FADE)
  animation.layer_fade(a.animator, a.layers[clip], 1, CROSS_FADE)
  animation.clip_seek(a.animator, a.layers[clip], 0)
  a.clip = clip
}

actor_busy :: proc(a: ^Actor) -> bool {
  if a.clip == .IDLE || a.clip == .RUN do return false
  return a.clip == .DEATH || !animation.clip_done(a.animator, a.layers[a.clip])
}

actor_move :: proc(a: ^Actor, moving: bool) {
  if !actor_busy(a) do actor_play(a, .RUN if moving else .IDLE)
}

actor_update :: proc(app: ^App, a: ^Actor, model: ^gltf.Model, dt: f32) {
  gltf.animate(&a.instance, model, &app.scene, &app.renderer, dt)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  if input.key_pressed(&app.input, .F1) do app.show_debug = !app.show_debug
  fsm.update(&app.screen, SCREENS, app, dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  draw_hud(app)
  render.update(&app.renderer, dt)
}

update_select :: proc(app: ^App, dt: f32) -> Screen {
  step := int(input.key_pressed(&app.input, .D) || input.key_pressed(&app.input, .RIGHT)) - int(input.key_pressed(&app.input, .A) || input.key_pressed(&app.input, .LEFT))
  if step != 0 {
    actor_play(&app.lineup[app.hero], .IDLE)
    app.hero = (app.hero + step + len(HEROES)) % len(HEROES)
    actor_play(&app.lineup[app.hero], .CHEER)
  }
  world.translate(&app.scene, app.spotlight, f32(app.hero) * 2.2 - 4.4, 5, 3)
  for &a, i in app.lineup {
    actor_move(&a, false)
    actor_update(app, &a, &app.heroes[i], dt)
  }
  if !input.key_pressed(&app.input, .ENTER) && !input.key_pressed(&app.input, .SPACE) do return .SELECT
  app.score = 0
  return .LEVEL_1
}

update_level :: proc(app: ^App, dt: f32) -> Screen {
  render.orbit_drag(&app.orbit, &app.input, {.RIGHT}, min_distance = 4, max_distance = 20)
  update_player(app, dt)
  physics.step(&app.phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  app.feet = physics.body(&app.phys, app.player.body).position - {0, BODY_HALF_HEIGHT, 0}
  nav.crowd_update(&app.crowd, dt)
  world.set_world_poses(&app.scene, nav.agent_poses(&app.crowd))
  update_enemies(app, dt)
  update_projectiles(app, dt)
  update_pickups(app, dt)
  app.orbit.target = app.feet + {0, 1.8, 0}
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if app.show_debug do draw_debug(app)
  if app.result_timer == 0 && len(app.enemies) == 0 && app.player.health > 0 {
    actor_play(&app.player, .CHEER)
    finish(app, true)
  }
  if app.result_timer > 0 {
    app.result_timer -= dt
    if app.result_timer <= 0 do return .RESULT
  }
  return app.screen.current
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
    if p.strike <= 0 do player_strike(app, hero, hero.damage * (2 if p.buffs[.STRENGTH] > 0 else 1))
  }
  speed := hero.speed * (1.6 if p.buffs[.SPEED] > 0 else 1)
  velocity := move * speed if p.clip != .ATTACK else 0
  vertical := JUMP_SPEED if jump else physics.body(&app.phys, p.body).velocity.y
  physics.set_velocity(&app.phys, p.body, {velocity.x, vertical, velocity.z})
  if linalg.length(move) > 0 do p.facing = math.atan2(move.x, move.z)
  world.rotate(&app.scene, p.model, p.facing)
  actor_update(app, p, &app.heroes[app.hero], dt)
}

move_direction :: proc(app: ^App) -> [3]f32 {
  cam := render.main_camera(&app.renderer)
  forward := render.camera_forward(cam) * {1, 0, 1}
  right := render.camera_right(cam) * {1, 0, 1}
  return linalg.normalize0(forward * input.axis(&app.input, .S, .W) + right * input.axis(&app.input, .A, .D))
}

on_ground :: proc(app: ^App) -> bool {
  feet := physics.body(&app.phys, app.player.body).position - {0, BODY_HALF_HEIGHT + 0.01, 0}
  return physics.raycast(&app.phys, geometry.Ray{origin = feet, direction = {0, -1, 0}}, 0.1, first_hit = true).hit
}

player_strike :: proc(app: ^App, hero: Hero, damage: f32) {
  forward := [2]f32{math.sin(app.player.facing), math.cos(app.player.facing)}
  if hero.shot != .NONE {
    direction := [3]f32{forward.x, 0, forward.y}
    shoot(app, hero.shot, app.feet + {0, 1.4, 0} + direction * 0.6, direction, damage, friendly = true)
    return
  }
  for &e in app.enemies {
    if e.health <= 0 do continue
    to := enemy_position(app, &e).xz - app.feet.xz
    reach := REACH + 0.5 * FOES[e.kind].scale
    if linalg.length(to) < reach && linalg.dot(linalg.normalize0(to), forward) > 0.2 do hurt_enemy(app, &e, damage)
  }
}

hurt_enemy :: proc(app: ^App, e: ^Enemy, damage: f32) {
  e.health -= damage
  render.emit(&app.renderer, app.emitters[.HIT], render.SlotHandle(e.chest.index), 40)
  if e.health > 0 {
    actor_play(e, .HIT)
    return
  }
  app.score += FOES[e.kind].score
  render.emit(&app.renderer, app.emitters[.DEATH], render.SlotHandle(e.model.index), 80)
}

hurt_player :: proc(app: ^App, damage: f32) {
  p := &app.player
  if p.health <= 0 || p.buffs[.SHIELD] > 0 do return
  p.health -= damage
  render.emit(&app.renderer, app.emitters[.HIT], render.SlotHandle(p.chest.index), 40)
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
  return nav.agent(&app.crowd, e.agent).position
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
    clear(&e.trace)
    if app.player.health > 0 || e.health <= 0 do bt.tick(brain(e.kind), &Mob{app, e}, &e.trace)
    agent := nav.agent(&app.crowd, e.agent)
    if e.health > 0 && (e.clip == .ATTACK || linalg.length(agent.velocity.xz) < 0.3) {
      to := app.feet - agent.position
      world.rotate(&app.scene, e.model, math.atan2(to.x, to.z))
    }
    actor_move(e, linalg.length(agent.velocity.xz) > 0.3)
    if e.strike > 0 {
      e.strike -= dt
      if e.strike <= 0 && e.health > 0 do enemy_strike(app, e)
    }
    actor_update(app, e, &app.foes[e.kind], dt)
    if e.dying > DESPAWN_TIME {
      nav.agent_destroy(&app.crowd, e.agent)
      actor_destroy(app, e)
      delete(e.trace)
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
  shoot(app, foe.shot, from, linalg.normalize0(app.feet + {0, 1.2, 0} - from), foe.damage, friendly = false)
}

shoot :: proc(app: ^App, shot: Shot, from, direction: [3]f32, damage: f32, friendly: bool) {
  node := world.spawn(&app.scene, from)
  world.rotate(&app.scene, node, linalg.quaternion_between_two_vector3([3]f32{0, 1, 0}, direction))
  instance: gltf.Instance
  if shot == .ARROW {
    instance = gltf.instance_create(&app.arrow, &app.scene, &app.renderer, parent = node)
  } else {
    render.attach(&app.renderer, render.SlotHandle(node.index), app.fireball)
    world.scale(&app.scene, node, 0.25)
    trail := world.spawn(&app.scene, parent = node)
    render.attach(&app.renderer, render.SlotHandle(trail.index), app.emitters[.MAGIC])
  }
  append(&app.projectiles, Projectile{friendly = friendly, node = node, instance = instance, position = from, velocity = direction * 12, damage = damage, life = 2})
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


is_dead :: proc(m: ^Mob) -> bool {
  return m.enemy.health <= 0
}

die :: proc(m: ^Mob) -> bt.Status {
  app, e := m.app, m.enemy
  if e.clip != .DEATH {
    actor_play(e, .DEATH)
    nav.stop(&app.crowd, e.agent)
  }
  return .RUNNING
}

in_range :: proc(m: ^Mob) -> bool {
  app, e := m.app, m.enemy
  return enemy_distance(app, e) <= FOES[e.kind].range
}

attack :: proc(m: ^Mob) -> bt.Status {
  app, e := m.app, m.enemy
  nav.stop(&app.crowd, e.agent)
  if e.cooldown <= 0 {
    actor_play(e, .ATTACK)
    e.cooldown = FOES[e.kind].cooldown
    e.strike = FOES[e.kind].windup
  }
  return .RUNNING
}

sees_player :: proc(m: ^Mob) -> bool {
  app, e := m.app, m.enemy
  return enemy_distance(app, e) <= SIGHT
}

chase :: proc(m: ^Mob) -> bt.Status {
  app, e := m.app, m.enemy
  if e.repath <= 0 {
    e.repath = 0.5
    nav.move_to(&app.crowd, e.agent, app.feet)
  }
  return .RUNNING
}

too_close :: proc(m: ^Mob) -> bool {
  app, e := m.app, m.enemy
  return enemy_distance(app, e) < FOES[e.kind].range * 0.4
}

retreat :: proc(m: ^Mob) -> bt.Status {
  app, e := m.app, m.enemy
  if e.repath <= 0 {
    e.repath = 0.5
    position := enemy_position(app, e)
    nav.move_to(&app.crowd, e.agent, position + linalg.normalize0(position - app.feet) * 4)
  }
  return .RUNNING
}

patrol :: proc(m: ^Mob) -> bt.Status {
  app, e := m.app, m.enemy
  if e.repath <= 0 {
    e.repath = 3
    nav.move_to(&app.crowd, e.agent, {rand.float32_range(-ARENA, ARENA), 0, rand.float32_range(-ARENA, ARENA)} * 0.7)
  }
  return .RUNNING
}

enraged :: proc(m: ^Mob) -> bool {
  e := m.enemy
  return e.health < FOES[e.kind].health * 0.5
}

charge :: proc(m: ^Mob) -> bt.Status {
  app, e := m.app, m.enemy
  nav.agent_params(&app.crowd, e.agent).max_speed = FOES[e.kind].speed * 1.8
  return chase(m)
}

update_projectiles :: proc(app: ^App, dt: f32) {
  for i := len(app.projectiles) - 1; i >= 0; i -= 1 {
    shot := &app.projectiles[i]
    shot.life -= dt
    shot.position += shot.velocity * dt
    world.translate(&app.scene, shot.node, shot.position)
    hit := false
    if shot.friendly {
      for &e in app.enemies {
        scale := FOES[e.kind].scale
        if e.health <= 0 || linalg.length(shot.position - enemy_position(app, &e) - {0, scale, 0}) > 0.8 * scale do continue
        hurt_enemy(app, &e, shot.damage)
        hit = true
        break
      }
    } else if linalg.length(shot.position - (app.feet + {0, 1.2, 0})) < 0.8 {
      hurt_player(app, shot.damage)
      hit = true
    }
    if hit || shot.life <= 0 {
      gltf.destroy(&shot.instance, &app.scene)
      world.destroy(&app.scene, shot.node)
      unordered_remove(&app.projectiles, i)
    }
  }
}

update_pickups :: proc(app: ^App, dt: f32) {
  for i := len(app.pickups) - 1; i >= 0; i -= 1 {
    pickup := &app.pickups[i]
    world.rotate_by(&app.scene, pickup.node, dt * 2)
    world.translate(&app.scene, pickup.node, pickup.base + {0, 0.2 * math.sin(app.screen.time * 3), 0})
    if app.player.health <= 0 || linalg.length(pickup.base.xz - app.feet.xz) > 1.2 do continue
    if pickup.power == .HEAL {
      app.player.health = min(app.player.health + 50, HEROES[app.hero].health)
    } else {
      app.player.buffs[pickup.power] = BUFF_TIME
    }
    render.emit(&app.renderer, app.emitters[.PICKUP], render.SlotHandle(app.player.chest.index), 60)
    gltf.destroy(&pickup.instance, &app.scene)
    world.destroy(&app.scene, pickup.node)
    unordered_remove(&app.pickups, i)
  }
}


draw_debug :: proc(app: ^App) {
  for h in app.bodies {
    body := physics.body(&app.phys, h) or_continue
    draw_collider(app, body)
  }
  render.debug_circle(&app.renderer, app.feet + {0, 0.05, 0}, {0, 1, 0}, REACH, render.DEBUG_RED)
  for &e in app.enemies {
    agent := nav.agent(&app.crowd, e.agent)
    lift := [3]f32{0, 0.1, 0}
    render.debug_circle(&app.renderer, agent.position + lift, {0, 1, 0}, agent.params.radius, render.DEBUG_YELLOW)
    from := agent.position + lift
    for corner in agent.corners[:agent.corner_count] {
      render.debug_segment(&app.renderer, from, corner + lift, render.DEBUG_CYAN)
      from = corner + lift
    }
  }
}

draw_collider :: proc(app: ^App, body: physics.Body) {
  switch shape in body.collider {
  case physics.BoxCollider:
    render.debug_cube(&app.renderer, body.position, body.rotation, shape.half_extents, render.DEBUG_GREEN)
  case physics.SphereCollider:
    render.debug_sphere(&app.renderer, body.position, shape.radius, render.DEBUG_GREEN)
  case physics.CylinderCollider:
    up := linalg.quaternion_mul_vector3(body.rotation, [3]f32{0, shape.half_height, 0})
    render.debug_circle(&app.renderer, body.position + up, up, shape.radius, render.DEBUG_GREEN)
    render.debug_circle(&app.renderer, body.position - up, up, shape.radius, render.DEBUG_GREEN)
  }
}

build_panel :: proc(app: ^App) {
  gui := &app.gui
  p := &app.panel
  screen := ui.node_create(gui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}, pin = {.STRETCH, .STRETCH}})
  p.root = ui.node_create(gui, {parent = screen, position = .ABSOLUTE, anchor = {0.5, 0.5}, direction = .COLUMN, padding = {28, 24, 28, 24}, gap = 14, align = {.CENTER, .CENTER}, hidden = true})
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

enter_result :: proc(app: ^App) {
  last := app.level == len(LEVELS) - 1
  ui.set_text(&app.gui, app.panel.title, ("Victory!" if !last else "The crypt is cleared!") if app.won else "Defeated")
  ui.set_text(&app.gui, app.panel.stats, fmt.tprintf("Level %d   Score %d", app.level + 1, app.score))
  ui.node(&app.gui, app.panel.next).hidden = !app.won || last
  ui.node(&app.gui, app.panel.root).hidden = false
}

exit_result :: proc(app: ^App) {
  ui.node(&app.gui, app.panel.root).hidden = true
}

update_result :: proc(app: ^App, dt: f32) -> Screen {
  ui.layout(&app.gui, render.window_size(&app.renderer), &app.font)
  ui.update_input(&app.gui, &app.input)
  actor_update(app, &app.player, &app.heroes[app.hero], dt)
  for &e in app.enemies do actor_update(app, &e, &app.foes[e.kind], dt)
  switch {
  case ui.clicked(&app.gui, app.panel.retry):
    if !app.won do app.score = 0
    return level_screen(app.level)
  case ui.clicked(&app.gui, app.panel.next):
    return level_screen(app.level + 1)
  case ui.clicked(&app.gui, app.panel.heroes):
    return .SELECT
  }
  return .RESULT
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}

draw_hud :: proc(app: ^App) {
  commands := make([dynamic]render.RenderCommand, context.temp_allocator)
  screen := render.window_size(&app.renderer)
  if app.screen.current == .SELECT {
    hero := HEROES[app.hero]
    text(&commands, "Choose your hero", {40, 36}, 40)
    text(&commands, fmt.tprintf("%s   health %.0f   speed %.1f   damage %.0f", hero.name, hero.health, hero.speed, hero.damage), {40, 90}, 24)
    text(&commands, "A / D choose     Enter start", {40, 126}, 20, {200, 200, 210, 255})
    text(&commands, CREDITS, {40, screen.y - 40}, 16, {200, 200, 210, 255})
  } else {
    hud(app, &commands)
  }
  if app.screen.current == .RESULT {
    for h, z in app.gui.draw_order {
      r := ui.rect(&app.gui, h)
      n := ui.node(&app.gui, h)
      if h == app.panel.root do append(&commands, render.RenderCommand{shape = render.DrawQuadCommand{position = r.pos, size = r.size, color = {20, 20, 30, 230}}, z_order = i32(z) + 100})
      if n.interactive {
        color: [4]u8 = {200, 90, 60, 255} if ui.hovered(&app.gui, h) else {150, 60, 45, 255}
        append(&commands, render.RenderCommand{shape = render.DrawQuadCommand{position = r.pos, size = r.size, color = color}, z_order = i32(z) + 100})
      }
      for line in ui.lines(&app.gui, h) {
        label := render.DrawTextCommand{text = n.text[line.start:line.end], position = line.pos, size = line.size, color = 255}
        append(&commands, render.RenderCommand{shape = label, z_order = i32(z) + 100})
      }
    }
  }
  render.stage_overlay(&app.renderer, commands[:], &app.font)
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
  text(commands, "WASD run   Space jump   Left click attack   Right drag look   F1 debug", {40, y + 8}, 16, {200, 200, 210, 255})
  for &e in app.enemies {
    if e.health <= 0 do continue
    head := enemy_position(app, &e) + {0, 2.4 * FOES[e.kind].scale, 0}
    point := render.world_to_screen(&app.renderer, head) or_continue
    bar(commands, point - {30, 0}, {60, 7}, e.health / FOES[e.kind].health, {230, 200, 60, 255})
    if !app.show_debug do continue
    y := point.y - 6
    #reverse for step in e.trace {
      y -= 16
      text(commands, fmt.tprintf("%s %v", step.name, step.status), {point.x - 30, y}, 13, TRACE_COLORS[step.status])
    }
  }
}

text :: proc(commands: ^[dynamic]render.RenderCommand, s: string, position: [2]f32, size: f32, color: [4]u8 = 255) {
  append(commands, render.RenderCommand{shape = render.DrawTextCommand{text = s, position = position, size = size, color = color}})
}

bar :: proc(commands: ^[dynamic]render.RenderCommand, position, size: [2]f32, fraction: f32, color: [4]u8) {
  append(commands, render.RenderCommand{shape = render.DrawQuadCommand{position = position, size = size, color = {0, 0, 0, 160}}})
  append(commands, render.RenderCommand{shape = render.DrawQuadCommand{position = position + 2, size = {(size.x - 4) * clamp(fraction, 0, 1), size.y - 4}, color = color}})
}
