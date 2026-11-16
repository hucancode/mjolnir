// A game HUD on the retained ux, over sample data: bars, hotbar, a skinned minimap, quest tracker, chat, toasts, draggable inventory, quest log and settings windows, and pause and quit dialogs.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/font"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/ui"
import "mjolnir/ux"
import "mjolnir/world"

REFERENCE :: [2]f32{1280, 720}
SHEET :: [2]f32{20, 9}
TILE :: 18
BOX_TILE :: 6
BUSH_TILE :: 17
COIN_TILE :: 151
BAG_COLUMNS :: 6
BAG_SIZE :: 24
HOTBAR :: 8
TOASTS :: 5
TOAST_SECONDS :: 4
KNIGHT_PROPS :: [?]string{"1H_Sword_Offhand", "2H_Sword", "Badge_Shield", "Rectangle_Shield", "Spike_Shield"}

Item :: enum u8 {
  NONE,
  POTION,
  MUSHROOM,
  GEM,
  SPROUT,
  CRATE,
  KEY,
}

ItemInfo :: struct {
  name, text: string,
  tile:       u32,
  value:      int,
  consumable: bool,
}

ITEMS := [Item]ItemInfo {
  .NONE     = {},
  .POTION   = {"Heart Potion", "Restores 120 health.", 44, 15, true},
  .MUSHROOM = {"Red Mushroom", "Restores 60 mana.", 128, 10, true},
  .GEM      = {"Sapphire", "A cold blue gem. Merchants love it.", 67, 80, false},
  .SPROUT   = {"Sprout", "A herb for the alchemist in town.", 124, 4, false},
  .CRATE    = {"Supply Crate", "Heavy. Something rattles inside.", 26, 25, false},
  .KEY      = {"Golden Key", "Opens the gate of the old crypt.", 27, 0, false},
}

Skill :: enum u8 {
  SPIKES,
  THORNS,
  FROST,
  RALLY,
}

SkillInfo :: struct {
  name:     string,
  tile:     u32,
  cooldown: f32,
}

SKILLS := [Skill]SkillInfo {
  .SPIKES = {"Spikes", 68, 1.5},
  .THORNS = {"Thorns", 127, 5},
  .FROST  = {"Frost", 145, 9},
  .RALLY  = {"Rally", 111, 20},
}

Action :: union {
  Skill,
  Item,
}

Quest :: struct {
  title, text, goal: string,
}

QUESTS := [?]Quest {
  {"Slime Season", "The vale is crawling with slimes again. The miller asks you to thin them out before the harvest.", "Slimes defeated 4 / 10\nReward 50 gold"},
  {"Shiny Things Hidden in Slime Bellies", "A jeweller in town pays well for sapphires. Slimes swallow them, for reasons nobody understands.", "Sapphires 1 / 5\nReward 120 gold"},
  {"Green Thumb", "The alchemist needs fresh sprouts for her tonics. They fall out of the slimes, oddly enough.", "Sprouts 3 / 6\nReward 40 gold"},
  {"Locked Out", "The old crypt is sealed by a golden key that one of the slimes is said to carry.", "Golden key 0 / 1\nReward 200 gold"},
  {"Seasoned", "Prove yourself in the field. The captain only talks to veterans.", "Level 7 / 10\nReward 150 gold"},
  {"Hoarder", "Every adventure needs funding. Save up a respectable sum.", "Gold 35 / 300"},
}

MAP_MARKERS := [?][2]f32{{0.2, 0.3}, {0.75, 0.2}, {0.8, 0.7}, {0.3, 0.8}, {0.55, 0.4}}

Window :: enum u8 {
  INVENTORY,
  QUESTS,
  SETTINGS,
  PAUSE,
}

MENU_BUTTONS := [Window]struct {
  label: string,
  key:   input.Key,
} {
  .INVENTORY = {"Bag", .I},
  .QUESTS    = {"Quests", .J},
  .SETTINGS  = {"Options", .O},
  .PAUSE     = {"Menu", .ESCAPE},
}

Styles :: struct {
  text, dim, gold, small:                    ux.StyleHandle,
  panel, button, slot, icon, badge:          ux.StyleHandle,
  bar, hp, mp, xp, map_, enemy, player:      ux.StyleHandle,
  tooltip, dim_screen, toast, row, row_text: ux.StyleHandle,
}

Slot :: struct {
  frame, icon, count: ux.NodeHandle,
}

Bar :: struct {
  fill, label: ux.NodeHandle,
}

Toast :: struct {
  node: ux.NodeHandle,
  life: f32,
}

Stack :: struct {
  item:  Item,
  count: int,
}

App :: struct {
  platform:    platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  input:       input.State,
  font:        font.Font,
  gui:         ux.UI,
  sweeps:      ui.Canvas,
  orbit:       render.Orbit,
  knight:      gltf.Model,
  hero:        gltf.Instance,
  sheet:       render.TextureHandle,
  tiles:       []render.SpriteFrame,
  s:           Styles,
  hero_name:   ux.NodeHandle,
  map_frame:   ux.NodeHandle,
  tracker:     ux.NodeHandle,
  chat:        ux.NodeHandle,
  hotbar:      [HOTBAR]Slot,
  menu:        [Window]ux.NodeHandle,
  toast_list:  ux.NodeHandle,
  tooltip:     ux.NodeHandle,
  tip_title:   ux.NodeHandle,
  tip_text:    ux.NodeHandle,
  ghost:       ux.NodeHandle,
  windows:     [Window]ux.NodeHandle,
  bag_slots:   [BAG_SIZE]Slot,
  quest_rows:  [len(QUESTS)]ux.NodeHandle,
  quest_name:  ux.NodeHandle,
  quest_text:  ux.NodeHandle,
  quest_goal:  ux.NodeHandle,
  track:       ux.NodeHandle,
  track_label: ux.NodeHandle,
  name_box:    ux.NodeHandle,
  map_check:   ux.NodeHandle,
  scale_knob:  ux.NodeHandle,
  resume:      ux.NodeHandle,
  quit:        ux.NodeHandle,
  bag:         [BAG_SIZE]Stack,
  actions:     [HOTBAR]Action,
  cooldowns:   [HOTBAR]f32,
  toasts:      [dynamic]Toast,
  tracked:     [len(QUESTS)]bool,
  quest:       int,
  dragging:    int,
  quitting:    bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "UI") do return
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
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  app.sheet = render.texture_create(&app.renderer, #load("assets/kenney_pixel_platformer/Tilemap/tilemap_packed.png"))
  app.tiles = render.sprite_frames_grid(u32(SHEET.x), u32(SHEET.y), allocator = context.allocator)
  app.knight = gltf.model_create(&app.renderer, #load("assets/kaykit_adventurers/Knight.glb"))
  app.hero = gltf.instance_create(&app.knight, &app.scene, &app.renderer)
  for name in KNIGHT_PROPS do if node, found := world.find(&app.scene, name, app.hero.root); found do world.set_visible(&app.scene, node, false)
  if len(app.hero.animators) > 0 do animation.play(&app.hero.animators[0], &app.knight.rigs[0], "Idle")
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), scale = 8)
  app.orbit = render.make_orbit({0, 2.2, 4.5}, {0, 1, 0})
  sample_data(app)
  ux.init(&app.gui, REFERENCE)
  create_styles(app)
  build_hud(app)
  build_windows(app)
  return .READY
}

sample_data :: proc(app: ^App) {
  app.bag[0] = {.POTION, 3}
  app.bag[1] = {.MUSHROOM, 2}
  app.bag[2] = {.SPROUT, 3}
  app.bag[3] = {.GEM, 1}
  app.bag[4] = {.CRATE, 1}
  app.actions = {Skill.SPIKES, Skill.THORNS, Skill.FROST, Skill.RALLY, Item.POTION, Item.MUSHROOM, nil, nil}
  app.tracked[0], app.tracked[1] = true, true
  app.dragging = -1
}

shutdown :: proc(app: ^App) {
  delete(app.toasts)
  delete(app.tiles)
  ui.destroy(&app.sweeps)
  ux.shutdown(&app.gui)
  font.destroy(&app.font)
  gltf.destroy(&app.hero, &app.scene, &app.renderer)
  gltf.destroy(&app.knight, &app.renderer)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

rgba :: proc(r, g, b: u8, a: u8 = 255) -> [4]u8 {
  return {r, g, b, a}
}

tile_skin :: proc(app: ^App, first, cells: u32, border, scale: f32, mode := [2]ui.SkinMode{}) -> ui.Skin {
  top_left := app.tiles[first].uv[0]
  bottom_right := app.tiles[first + (cells - 1) * u32(SHEET.x) + cells - 1].uv[2]
  uv := [4][2]f32{top_left, {bottom_right.x, top_left.y}, bottom_right, {top_left.x, bottom_right.y}}
  return {image = u32(app.sheet), uv = uv, size = f32(cells * TILE), border = border, scale = scale, mode = mode}
}

create_styles :: proc(app: ^App) {
  gui := &app.gui
  WHITE :: [4]u8{235, 235, 242, 255}
  GOLD :: [4]u8{236, 196, 104, 255}
  EDGE :: [4]u8{74, 80, 104, 255}
  s := &app.s
  s.text = ux.style_create(gui, {color = WHITE})
  s.dim = ux.style_create(gui, {color = rgba(160, 166, 184)})
  s.gold = ux.style_create(gui, {color = GOLD})
  s.small = ux.style_create(gui, {color = rgba(210, 214, 228)})
  s.panel = ux.style_create(gui, {fill = rgba(16, 18, 26, 215), border = 1, border_color = EDGE})
  button := ux.Style{fill = rgba(48, 54, 74), border = 1, border_color = rgba(88, 96, 124), color = WHITE}
  hover := button
  hover.fill, hover.border_color = rgba(66, 74, 100), GOLD
  press := button
  press.fill = rgba(34, 38, 52)
  active := button
  active.fill, active.border_color, active.color = rgba(132, 98, 44), GOLD, WHITE
  s.button = ux.style_create(gui, button, hover, press, active)
  slot := ux.Style{fill = rgba(12, 14, 20, 230), border = 1, border_color = EDGE}
  slot_hover := slot
  slot_hover.border_color = GOLD
  slot_active := slot
  slot_active.fill = rgba(40, 34, 20, 230)
  s.slot = ux.style_create(gui, slot, slot_hover, slot_hover, slot_active)
  s.icon = ux.style_create(gui, {color = WHITE}, nil, nil, ux.Style{color = rgba(255, 255, 255, 70)})
  s.badge = ux.style_create(gui, {skin = tile_skin(app, BOX_TILE, 1, 6, 2)})
  s.bar = ux.style_create(gui, {fill = rgba(8, 8, 12, 200), border = 1, border_color = rgba(0, 0, 0, 255), color = WHITE})
  s.hp = ux.style_create(gui, {fill = rgba(196, 48, 52)})
  s.mp = ux.style_create(gui, {fill = rgba(52, 108, 220)})
  s.xp = ux.style_create(gui, {fill = rgba(160, 120, 236)})
  s.map_ = ux.style_create(gui, {fill = rgba(28, 52, 40, 225), skin = tile_skin(app, BUSH_TILE, 3, TILE, 1, {.REPEAT, .REPEAT})})
  s.enemy = ux.style_create(gui, {fill = rgba(230, 70, 60)})
  s.player = ux.style_create(gui, {fill = rgba(250, 230, 120)})
  s.tooltip = ux.style_create(gui, {fill = rgba(10, 10, 16), border = 1, border_color = rgba(130, 108, 66)})
  s.dim_screen = ux.style_create(gui, {fill = rgba(0, 0, 0, 150)})
  s.toast = ux.style_create(gui, {fill = rgba(10, 10, 16, 190), color = WHITE})
  row := ux.Style{color = WHITE}
  row_hover := ux.Style{fill = rgba(50, 54, 72), color = WHITE}
  row_active := ux.Style{fill = rgba(96, 74, 38), color = GOLD}
  s.row = ux.style_create(gui, row, row_hover, row_hover, row_active)
  s.row_text = ux.style_create(gui, {color = WHITE}, nil, nil, ux.Style{color = GOLD})
  t := &gui.theme
  t.text, t.button, t.heading = s.text, s.button, s.gold
  t.window = ux.style_create(gui, {fill = rgba(20, 22, 32), border = 2, border_color = rgba(110, 92, 58)})
  t.title = ux.style_create(gui, {fill = rgba(38, 34, 30)}, ux.Style{fill = rgba(48, 42, 34)})
  t.close = ux.style_create(gui, {color = rgba(200, 190, 170)}, ux.Style{fill = rgba(170, 50, 45), color = WHITE})
  t.panel = ux.style_create(gui, {fill = rgba(10, 12, 18), border = 1, border_color = EDGE})
}

add :: proc(app: ^App, parent: ux.NodeHandle, n: ux.Node) -> ux.NodeHandle {
  n := n
  n.parent = parent
  return ux.node_create(&app.gui, n)
}

slot :: proc(app: ^App, parent: ux.NodeHandle, size: f32, key := "") -> Slot {
  s: Slot
  s.frame = add(app, parent, {size = ux.fixed(size, size), padding = {6, 6, 6, 6}, interactive = true, style = app.s.slot})
  s.icon = add(app, s.frame, {size = {ux.percent(1), ux.percent(1)}, style = app.s.icon, hidden = true, image = u32(app.sheet), overlay = true})
  s.count = add(app, s.frame, {font_size = 13, style = app.s.text, position = .ABSOLUTE, anchor = {1, 1}, offset = {-4, -2}})
  if key != "" do add(app, s.frame, {text = key, font_size = 12, style = app.s.dim, position = .ABSOLUTE, offset = {4, 2}})
  return s
}

bar :: proc(app: ^App, parent: ux.NodeHandle, width, height: f32, fill: ux.StyleHandle, font_size: f32 = 13) -> Bar {
  back := add(app, parent, {size = ux.fixed(width, height), style = app.s.bar})
  b: Bar
  b.fill = add(app, back, {size = {ux.percent(1), ux.percent(1)}, style = fill})
  if font_size > 0 do b.label = add(app, back, {font_size = font_size, style = app.s.text, position = .ABSOLUTE, anchor = {0.5, 0.5}})
  return b
}

build_hud :: proc(app: ^App) {
  gui := &app.gui
  s := &app.s
  screen := ux.node_create(gui, {size = {ux.percent(1), ux.percent(1)}})

  frame := add(app, screen, {position = .ABSOLUTE, offset = {16, 16}, padding = {10, 10, 12, 10}, gap = 12, align = {.START, .CENTER}, style = s.panel})
  badge := add(app, frame, {size = ux.fixed(56, 56), align = {.CENTER, .CENTER}, direction = .COLUMN, style = s.badge})
  ux.label(gui, badge, "LV", 11, s.dim)
  ux.label(gui, badge, "7", 24, s.gold)
  column := add(app, frame, {direction = .COLUMN, gap = 5})
  app.hero_name = ux.label(gui, column, "Sir Aldric", 17, s.gold)
  set_bar(app, bar(app, column, 250, 18, s.hp), 240, 300)
  set_bar(app, bar(app, column, 250, 14, s.mp, 11), 90, 130)
  set_bar(app, bar(app, column, 250, 6, s.xp, 0), 140, 200)

  top_right := add(app, screen, {position = .ABSOLUTE, anchor = {1, 0}, offset = {-16, 16}, direction = .COLUMN, gap = 6, align = {.END, .START}})
  ux.label(gui, top_right, "Whispering Vale", 18, s.gold)
  app.map_frame = add(app, top_right, {size = ux.fixed(176, 176), clip = true, style = s.map_})
  add(app, app.map_frame, {position = .ABSOLUTE, anchor = {0.5, 0.5}, size = ux.fixed(10, 10), style = s.player, z = 1})
  for m in MAP_MARKERS do add(app, app.map_frame, {position = .ABSOLUTE, anchor = m, size = ux.fixed(7, 7), style = s.enemy})
  gold := add(app, top_right, {gap = 6, align = {.END, .CENTER}, padding = {8, 4, 8, 4}, style = s.panel})
  add(app, gold, {size = ux.fixed(18, 18), style = s.icon, image = u32(app.sheet), image_uv = app.tiles[COIN_TILE].uv})
  ux.label(gui, gold, "35", 16, s.gold)

  tracker := add(app, screen, {position = .ABSOLUTE, anchor = {0, 0.4}, offset = {16, 0}, direction = .COLUMN, gap = 6, padding = {12, 10, 12, 10}, style = s.panel})
  ux.label(gui, tracker, "Quests", 16, s.gold)
  app.tracker = ux.label(gui, tracker, "", 14, s.small)

  chat := add(app, screen, {position = .ABSOLUTE, anchor = {0, 1}, offset = {16, -16}, direction = .COLUMN, gap = 6, padding = {10, 8, 10, 10}, style = s.panel})
  ux.label(gui, chat, "Enter to chat", 12, s.dim)
  app.chat = ux.text_box(gui, chat, "", 280)

  hotbar := add(app, screen, {position = .ABSOLUTE, anchor = {0.5, 1}, offset = {0, -16}, gap = 6, padding = {8, 8, 8, 8}, style = s.panel})
  for &h, i in app.hotbar do h = slot(app, hotbar, 56, fmt.tprint(i + 1))

  menu := add(app, screen, {position = .ABSOLUTE, anchor = {1, 1}, offset = {-16, -16}, gap = 6, padding = {8, 8, 8, 8}, style = s.panel})
  for &b, w in app.menu {
    b = add(app, menu, {direction = .COLUMN, size = ux.fixed(62, 50), align = {.CENTER, .CENTER}, interactive = true, style = s.button})
    ux.label(gui, b, MENU_BUTTONS[w].label, 15)
    ux.label(gui, b, "Esc" if MENU_BUTTONS[w].key == .ESCAPE else fmt.tprint(MENU_BUTTONS[w].key), 11, s.dim)
  }

  app.toast_list = add(app, screen, {position = .ABSOLUTE, anchor = {0.5, 1}, offset = {0, -110}, direction = .COLUMN, gap = 6, align = {.CENTER, .END}})

  app.tooltip = ux.node_create(gui, {direction = .COLUMN, gap = 4, padding = {12, 10, 12, 10}, z = 5000, hidden = true, style = s.tooltip})
  app.tip_title = ux.label(gui, app.tooltip, "", 16, s.gold)
  app.tip_text = add(app, app.tooltip, {font_size = 14, style = s.small, size = {{.FIXED, 230}, {}}, wrap = true})
  app.ghost = ux.node_create(gui, {size = ux.fixed(44, 44), z = 6000, hidden = true, style = s.icon, image = u32(app.sheet)})
}

window :: proc(app: ^App, w: Window, title: string, width: f32, offset: [2]f32) -> (body: ux.NodeHandle) {
  app.windows[w], body, _ = ux.window(&app.gui, title, width, offset)
  ux.node(&app.gui, app.windows[w]).hidden = true
  return
}

build_windows :: proc(app: ^App) {
  gui := &app.gui
  s := &app.s
  body := window(app, .INVENTORY, "Inventory", 400, {700, 150})
  grid := add(app, body, {direction = .COLUMN, gap = 6})
  row: ux.NodeHandle
  for &b, i in app.bag_slots {
    if i % BAG_COLUMNS == 0 do row = add(app, grid, {gap = 6})
    b = slot(app, row, 56)
  }
  footer := add(app, body, {size = {ux.grow(), {}}, gap = 8, align = {.START, .CENTER}})
  add(app, footer, {size = ux.fixed(20, 20), style = s.icon, image = u32(app.sheet), image_uv = app.tiles[COIN_TILE].uv})
  ux.label(gui, footer, "35 gold", 16, s.gold)
  add(app, body, {text = "Drag to move, drop on the hotbar to bind, right click to use.", font_size = 13, style = s.dim, size = {ux.grow(), {}}, wrap = true})

  body = window(app, .QUESTS, "Quest Log", 560, {120, 120})
  split := add(app, body, {gap = 14, size = {ux.grow(), {.FIXED, 300}}})
  list := ux.scroll_view(gui, split, {{.FIXED, 200}, ux.grow()})
  for &r, i in app.quest_rows {
    r = add(app, list, {size = {ux.grow(), {.FIXED, 58}}, padding = {10, 0, 10, 0}, align = {.START, .CENTER}, interactive = true, style = s.row})
    add(app, r, {text = QUESTS[i].title, font_size = 15, style = s.row_text, size = {ux.grow(), {}}, truncate = true})
  }
  detail := add(app, split, {direction = .COLUMN, size = {ux.grow(), ux.grow()}, gap = 10})
  app.quest_name = add(app, detail, {font_size = 20, style = s.gold, size = {ux.grow(), {}}, wrap = true})
  app.quest_text = add(app, detail, {font_size = 14, style = s.small, size = {ux.grow(), {}}, wrap = true})
  app.quest_goal = ux.label(gui, detail, "", 15)
  add(app, detail, {size = {{}, ux.grow()}})
  app.track = add(app, detail, {size = ux.fixed(120, 34), align = {.CENTER, .CENTER}, interactive = true, style = s.button})
  app.track_label = ux.label(gui, app.track, "Track", 16)

  body = window(app, .SETTINGS, "Options", 340, {460, 200})
  name := add(app, body, {gap = 10, align = {.START, .CENTER}})
  ux.label(gui, name, "Name", 15, s.small)
  app.name_box = ux.text_box(gui, name, "Sir Aldric", 220)
  app.map_check = ux.check(gui, body, "Show minimap", true)
  scale := add(app, body, {gap = 10, align = {.START, .CENTER}})
  ux.label(gui, scale, "UI scale", 15, s.small)
  app.scale_knob = ux.slider(gui, scale, 0.5, 180)

  root := ux.node_create(gui, {size = {ux.percent(1), ux.percent(1)}, align = {.CENTER, .CENTER}, interactive = true, hidden = true, style = s.dim_screen})
  app.windows[.PAUSE] = root
  box := add(app, root, {direction = .COLUMN, padding = {28, 22, 28, 24}, gap = 14, align = {.CENTER, .START}, style = gui.theme.window})
  ux.label(gui, box, "Paused", 26, s.gold)
  app.resume = ux.button(gui, box, "Resume", ux.fixed(220, 40))
  app.quit = ux.button(gui, box, "Quit to desktop", ux.fixed(220, 40))
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  mjolnir.update_ui_input(&app.platform, &app.gui, &app.input)
  handle_hud(app)
  handle_inventory(app)
  handle_panels(app)
  handle_keys(app)
  refresh(app, dt)
  camera := render.main_camera(&app.renderer)
  mjolnir.orbit_drag(&app.orbit, camera, &app.input)
  draw_sweeps(app)
  mjolnir.stage_ui(&app.renderer, &app.platform, &app.gui, &app.font, {&app.sweeps})
  mjolnir.update(&app.scene, &app.renderer, dt)
  gltf.animate(&app.hero, &app.knight, &app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return !app.quitting && mjolnir.frame(&app.platform, &app.renderer)
}

is_open :: proc(app: ^App, w: Window) -> bool {
  return !ux.node(&app.gui, app.windows[w]).hidden
}

open_window :: proc(app: ^App, w: Window, open := true) {
  ux.node(&app.gui, app.windows[w]).hidden = !open
  if open do ux.raise(&app.gui, app.windows[w])
}

topmost :: proc(app: ^App) -> (top: Window, ok: bool) {
  order := min(i32)
  for w in Window do if is_open(app, w) {
    if o := ux.node(&app.gui, app.windows[w]).order; o > order {
      top, order, ok = w, o, true
    }
  }
  return
}

handle_hud :: proc(app: ^App) {
  gui := &app.gui
  for b, w in app.menu do if ux.clicked(gui, b) do open_window(app, w, !is_open(app, w))
  for h, i in app.hotbar {
    if ux.clicked(gui, h.frame) do use_action(app, i)
    if ux.clicked(gui, h.frame, .RIGHT) do app.actions[i] = nil
  }
  if ux.submitted(gui, app.chat) {
    if said := ux.node(gui, app.chat).text; said != "" do toast(app, fmt.tprintf("%s: %s", ux.node(gui, app.hero_name).text, said))
    ux.set_text(gui, app.chat, "")
    ux.focus(gui, {})
  }
}

handle_inventory :: proc(app: ^App) {
  gui := &app.gui
  app.dragging = -1
  for b, i in app.bag_slots {
    item := app.bag[i].item
    if item == .NONE do continue
    if ux.pressed(gui, b.frame) do app.dragging = i
    if ux.clicked(gui, b.frame, .RIGHT) do use_item(app, item)
    for to, j in app.bag_slots do if ux.dropped(gui, b.frame, to.frame) do app.bag[i], app.bag[j] = app.bag[j], app.bag[i]
    for to, j in app.hotbar do if ux.dropped(gui, b.frame, to.frame) {
      if ITEMS[item].consumable do app.actions[j] = item
      else do toast(app, fmt.tprintf("%s cannot be used from the hotbar", ITEMS[item].name))
    }
  }
}

handle_panels :: proc(app: ^App) {
  gui := &app.gui
  for r, i in app.quest_rows do if ux.clicked(gui, r) do app.quest = i
  if ux.clicked(gui, app.track) do app.tracked[app.quest] = !app.tracked[app.quest]
  if ux.clicked(gui, app.resume) do open_window(app, .PAUSE, false)
  if ux.clicked(gui, app.quit) do app.quitting = true
  if ux.submitted(gui, app.name_box) || ux.changed(gui, app.name_box) {
    ux.set_text(gui, app.hero_name, ux.node(gui, app.name_box).text)
  }
  if ux.changed(gui, app.map_check) do toast(app, "Minimap shown" if ux.node(gui, app.map_check).active else "Minimap hidden")
  if ux.changed(gui, app.scale_knob) {
    gui.reference = REFERENCE / (0.75 + ux.node(gui, app.scale_knob).anchor.x * 0.5)
  }
}

handle_keys :: proc(app: ^App) {
  s := &app.input
  if s.keyboard_captured do return
  if input.key_pressed(s, .ESCAPE) {
    if w, ok := topmost(app); ok do open_window(app, w, false)
    else do open_window(app, .PAUSE)
  }
  if is_open(app, .PAUSE) do return
  for w in Window do if w != .PAUSE && input.key_pressed(s, MENU_BUTTONS[w].key) do open_window(app, w, !is_open(app, w))
  if input.key_pressed(s, .ENTER) do ux.focus(&app.gui, app.chat)
  if input.key_pressed(s, .M) {
    check := ux.node(&app.gui, app.map_check)
    check.active = !check.active
  }
  for i in 0 ..< HOTBAR do if input.key_pressed(s, input.Key(int(input.Key.NUM_1) + i)) do use_action(app, i)
}

use_action :: proc(app: ^App, slot: int) {
  if app.cooldowns[slot] > 0 do return
  switch a in app.actions[slot] {
  case Skill:
    app.cooldowns[slot] = SKILLS[a].cooldown
    toast(app, fmt.tprintf("Cast %s", SKILLS[a].name))
  case Item:
    if use_item(app, a) do app.cooldowns[slot] = 1
  }
}

use_item :: proc(app: ^App, item: Item) -> bool {
  if !ITEMS[item].consumable do return false
  for &stack in app.bag do if stack.item == item {
    toast(app, fmt.tprintf("Used %s", ITEMS[item].name))
    stack.count -= 1
    if stack.count == 0 do stack = {}
    return true
  }
  toast(app, fmt.tprintf("No %s left", ITEMS[item].name))
  return false
}

has :: proc(app: ^App, item: Item) -> (count: int) {
  for s in app.bag do if s.item == item do count += s.count
  return
}

toast :: proc(app: ^App, text: string) {
  if len(app.toasts) == TOASTS {
    ux.destroy(&app.gui, app.toasts[0].node)
    ordered_remove(&app.toasts, 0)
  }
  node := add(app, app.toast_list, {text = text, font_size = 15, style = app.s.toast, padding = {12, 6, 12, 6}})
  append(&app.toasts, Toast{node, TOAST_SECONDS})
}

set_icon :: proc(app: ^App, s: Slot, tile: u32, shown: bool) {
  icon := ux.node(&app.gui, s.icon)
  icon.hidden = !shown
  icon.image_uv = app.tiles[tile].uv
}

set_bar :: proc(app: ^App, b: Bar, value, total: f32) {
  ux.node(&app.gui, b.fill).size.x = {.PERCENT, clamp(value / max(total, 1), 0, 1)}
  if b.label != {} do ux.set_text(&app.gui, b.label, fmt.tprintf("%.0f / %.0f", value, total))
}

refresh :: proc(app: ^App, dt: f32) {
  gui := &app.gui
  ux.node(gui, app.map_frame).hidden = !ux.node(gui, app.map_check).active

  b := strings.builder_make(context.temp_allocator)
  for q, i in QUESTS do if app.tracked[i] do fmt.sbprintf(&b, "%s%s", "\n" if strings.builder_len(b) > 0 else "", q.title)
  ux.set_text(gui, app.tracker, strings.to_string(b) if strings.builder_len(b) > 0 else "No quests tracked")

  for h, i in app.hotbar {
    tile: u32
    count := ""
    switch a in app.actions[i] {
    case Skill:
      tile = SKILLS[a].tile
    case Item:
      tile = ITEMS[a].tile
      count = fmt.tprint(has(app, a))
    }
    set_icon(app, h, tile, app.actions[i] != nil)
    ux.set_text(gui, h.count, count)
    app.cooldowns[i] = max(app.cooldowns[i] - dt, 0)
  }
  for &t in app.toasts {
    t.life -= dt
    ux.node(gui, t.node).tint = {255, 255, 255, u8(255 * clamp(t.life, 0, 1))}
  }
  for len(app.toasts) > 0 && app.toasts[0].life <= 0 {
    ux.destroy(gui, app.toasts[0].node)
    ordered_remove(&app.toasts, 0)
  }

  for b, i in app.bag_slots {
    stack := app.bag[i]
    set_icon(app, b, ITEMS[stack.item].tile, stack.item != .NONE)
    ux.node(gui, b.icon).active = i == app.dragging
    ux.set_text(gui, b.count, fmt.tprint(stack.count) if stack.count > 1 else "")
  }
  ghost := ux.node(gui, app.ghost)
  ghost.hidden = app.dragging < 0
  if app.dragging >= 0 {
    ghost.image_uv = app.tiles[ITEMS[app.bag[app.dragging].item].tile].uv
    ux.place(gui, app.ghost, app.input.cursor - ux.rect(gui, app.ghost).size / 2)
  }

  for r, i in app.quest_rows do ux.node(gui, r).active = i == app.quest
  q := QUESTS[app.quest]
  ux.set_text(gui, app.quest_name, q.title)
  ux.set_text(gui, app.quest_text, q.text)
  ux.set_text(gui, app.quest_goal, q.goal)
  ux.set_text(gui, app.track_label, "Untrack" if app.tracked[app.quest] else "Track")

  tooltip(app)
}

tooltip :: proc(app: ^App) {
  gui := &app.gui
  title, text := "", ""
  if app.dragging < 0 && is_open(app, .INVENTORY) {
    for b, i in app.bag_slots do if ux.hovered(gui, b.frame) && app.bag[i].item != .NONE {
      info := ITEMS[app.bag[i].item]
      title = info.name
      text = fmt.tprintf("%s\nWorth %d gold%s", info.text, info.value, "\nRight click to use" if info.consumable else "")
    }
  }
  ux.node(gui, app.tooltip).hidden = title == ""
  if title == "" do return
  ux.set_text(gui, app.tip_title, title)
  ux.set_text(gui, app.tip_text, text)
  ux.place(gui, app.tooltip, app.input.cursor + 18)
}

draw_sweeps :: proc(app: ^App) {
  SEGMENTS :: 48
  SHADE :: [4]u8{0, 0, 0, 170}
  c := &app.sweeps
  ui.reset(c)
  c.dpi = platform.dpi_scale(&app.platform)
  for h, i in app.hotbar {
    total: f32 = 1
    if skill, ok := app.actions[i].(Skill); ok do total = SKILLS[skill].cooldown
    left := app.cooldowns[i] / total
    if left <= 0 do continue
    area := ux.rect(&app.gui, h.frame)
    c.z, c.clip = ux.layer(&app.gui, h.icon), area
    center := area.pos + area.size / 2
    radius := linalg.length(area.size) / 2
    n := max(int(math.ceil(left * SEGMENTS)), 1)
    vertices := make([]ui.Vertex2D, n + 2, context.temp_allocator)
    indices := make([]u32, n * 3, context.temp_allocator)
    vertices[0] = {pos = center, color = SHADE}
    for k in 0 ..= n {
      a := math.TAU * (1 - left * f32(n - k) / f32(n))
      vertices[k + 1] = {pos = center + radius * [2]f32{math.sin(a), -math.cos(a)}, color = SHADE}
    }
    for k in 0 ..< n do indices[k * 3], indices[k * 3 + 1], indices[k * 3 + 2] = 0, u32(k + 1), u32(k + 2)
    ui.triangles(c, vertices, indices)
  }
}
