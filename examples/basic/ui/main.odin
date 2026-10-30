// A game HUD on the retained ui, over sample data: bars, hotbar, minimap, tracker, toasts, and draggable inventory, character, quest and settings windows.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:time"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/font"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/ui"
import "mjolnir/world"

REFERENCE :: [2]f32{1280, 720}
SHEET :: [2]f32{20, 9}
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
  stack:      int,
  consumable: bool,
}

ITEMS := [Item]ItemInfo {
  .NONE     = {},
  .POTION   = {"Heart Potion", "Restores 120 health.", 44, 15, 20, true},
  .MUSHROOM = {"Red Mushroom", "Restores 60 mana.", 128, 10, 20, true},
  .GEM      = {"Sapphire", "A cold blue gem. Merchants love it.", 67, 80, 10, false},
  .SPROUT   = {"Sprout", "A herb for the alchemist in town.", 124, 4, 30, false},
  .CRATE    = {"Supply Crate", "Heavy. Something rattles inside.", 26, 25, 1, false},
  .KEY      = {"Golden Key", "Opens the gate of the old crypt.", 27, 0, 1, false},
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

Stat :: enum u8 {
  STRENGTH,
  DEXTERITY,
  INTELLECT,
  VITALITY,
}

Quest :: struct {
  title, text, goal: string,
}

QUESTS := [?]Quest {
  {"Slime Season", "The vale is crawling with slimes again. The miller asks you to thin them out before the harvest.", "Slimes defeated 4 / 10\nReward 50 gold"},
  {"Shiny Things", "A jeweller in town pays well for sapphires. Slimes swallow them, for reasons nobody understands.", "Sapphires 1 / 5\nReward 120 gold"},
  {"Green Thumb", "The alchemist needs fresh sprouts for her tonics. They fall out of the slimes, oddly enough.", "Sprouts 3 / 6\nReward 40 gold"},
  {"Locked Out", "The old crypt is sealed by a golden key that one of the slimes is said to carry.", "Golden key 0 / 1\nReward 200 gold"},
  {"Seasoned", "Prove yourself in the field. The captain only talks to veterans.", "Level 7 / 10\nReward 150 gold"},
  {"Hoarder", "Every adventure needs funding. Save up a respectable sum.", "Gold 35 / 300"},
}

MAP_MARKERS := [?][2]f32{{0.2, 0.3}, {0.75, 0.2}, {0.8, 0.7}, {0.3, 0.8}, {0.55, 0.4}}

Window :: enum u8 {
  INVENTORY,
  CHARACTER,
  QUESTS,
  SETTINGS,
  PAUSE,
  CONFIRM,
}

Tab :: enum u8 {
  GAMEPLAY,
  VIDEO,
  AUDIO,
  CONTROLS,
}

Setting :: enum u8 {
  SENSITIVITY,
  FOV,
  MASTER,
  MUSIC,
  EFFECTS,
}

SETTING_RANGE := [Setting][3]f32 {
  .SENSITIVITY = {0.25, 3, 1},
  .FOV         = {50, 110, 80},
  .MASTER      = {0, 100, 80},
  .MUSIC       = {0, 100, 60},
  .EFFECTS     = {0, 100, 90},
}

Toggle :: enum u8 {
  MINIMAP,
  PERF,
  TOASTS,
}

MenuButton :: enum u8 {
  CHARACTER,
  INVENTORY,
  QUESTS,
  SETTINGS,
  MENU,
}

MENU_BUTTONS := [MenuButton]struct {
  label, key: string,
} {
  .CHARACTER = {"Hero", "C"},
  .INVENTORY = {"Bag", "I"},
  .QUESTS    = {"Quests", "J"},
  .SETTINGS  = {"Options", "O"},
  .MENU      = {"Menu", "Esc"},
}

Styles :: struct {
  text, dim, gold, good, title, small:           ui.StyleHandle,
  panel, window, title_bar, close, button, tab:  ui.StyleHandle,
  slot, icon, cooldown, bar, hp, mp, xp:         ui.StyleHandle,
  map_, enemy, player, tooltip, dim_screen:      ui.StyleHandle,
  toast, check, track, track_fill, knob, row:    ui.StyleHandle,
  row_text:                                      ui.StyleHandle,
}

Slot :: struct {
  frame, icon, cooldown, count: ui.NodeHandle,
}

Bar :: struct {
  fill, label: ui.NodeHandle,
}

Slider :: struct {
  track, fill, knob, value: ui.NodeHandle,
}

Panel :: struct {
  root, title, close: ui.NodeHandle,
}

Toast :: struct {
  node: ui.NodeHandle,
  life: f32,
}

Stack :: struct {
  item:  Item,
  count: int,
}

App :: struct {
  platform:   platform.Platform,
  scene:      world.World,
  renderer:   render.Renderer,
  input:      input.State,
  font:       font.Font,
  gui:        ui.UI,
  orbit:      render.Orbit,
  knight:     gltf.Model,
  hero:       gltf.Instance,
  sheet:      render.TextureHandle,
  s:          Styles,
  map_frame:  ui.NodeHandle,
  perf:       ui.NodeHandle,
  tracker:    ui.NodeHandle,
  hotbar:     [HOTBAR]Slot,
  menu:       [MenuButton]ui.NodeHandle,
  toast_list: ui.NodeHandle,
  tooltip:    ui.NodeHandle,
  tip_title:  ui.NodeHandle,
  tip_text:   ui.NodeHandle,
  ghost:      ui.NodeHandle,
  panels:     [Window]Panel,
  open:       [Window]bool,
  top_z:      i32,
  bag_slots:  [BAG_SIZE]Slot,
  sort:       ui.NodeHandle,
  points:     ui.NodeHandle,
  stat_value: [Stat]ui.NodeHandle,
  stat_plus:  [Stat]ui.NodeHandle,
  quest_list: ui.NodeHandle,
  quest_rows: [len(QUESTS)]ui.NodeHandle,
  quest_name: ui.NodeHandle,
  quest_text: ui.NodeHandle,
  quest_goal: ui.NodeHandle,
  track:      ui.NodeHandle,
  track_label: ui.NodeHandle,
  tabs:       [Tab]ui.NodeHandle,
  pages:      [Tab]ui.NodeHandle,
  sliders:    [Setting]Slider,
  toggles:    [Toggle]ui.NodeHandle,
  reset:      ui.NodeHandle,
  resume:     ui.NodeHandle,
  options:    ui.NodeHandle,
  quit:       ui.NodeHandle,
  yes, no:    ui.NodeHandle,
  unspent:    int,
  stats:      [Stat]int,
  bag:        [BAG_SIZE]Stack,
  actions:    [HOTBAR]Action,
  cooldowns:  [HOTBAR]f32,
  toasts:     [dynamic]Toast,
  tracked:    [len(QUESTS)]bool,
  quest:      int,
  tab:        Tab,
  values:     [Setting]f32,
  shown:      [Toggle]bool,
  dragging:   int,
  perf_tick:  f32,
  frames:     int,
  layouts:    int,
  paints:     int,
  ui_time:    time.Duration,
  quitting:   bool,
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
  app.sheet = render.texture_create(&app.renderer, #load("assets/kenney_pixel_platformer/Tilemap/tilemap_packed.png")) or_else 0
  ok: bool
  app.knight, ok = gltf.model_create(&app.renderer, #load("assets/kaykit_adventurers/Knight.glb"))
  if !ok do return .FAIL
  app.hero = gltf.instance_create(&app.knight, &app.scene, &app.renderer)
  for name in KNIGHT_PROPS do if node, found := world.find(&app.scene, name, app.hero.root); found do world.set_visible(&app.scene, node, false)
  if len(app.hero.animators) > 0 do animation.play(&app.hero.animators[0], &app.knight.rigs[0], "Idle")
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), scale = 8)
  app.orbit = render.make_orbit({0, 2.2, 4.5}, {0, 1, 0})
  sample_data(app)
  ui.init(&app.gui, REFERENCE)
  create_styles(app)
  build_hud(app)
  build_windows(app)
  return .READY
}

sample_data :: proc(app: ^App) {
  app.stats = {.STRENGTH = 12, .DEXTERITY = 9, .INTELLECT = 7, .VITALITY = 11}
  app.unspent = 3
  app.bag[0] = {.POTION, 3}
  app.bag[1] = {.MUSHROOM, 2}
  app.bag[2] = {.SPROUT, 3}
  app.bag[3] = {.GEM, 1}
  app.bag[4] = {.CRATE, 1}
  app.actions = {Skill.SPIKES, Skill.THORNS, Skill.FROST, Skill.RALLY, Item.POTION, Item.MUSHROOM, nil, nil}
  app.tracked[0], app.tracked[1] = true, true
  app.dragging = -1
  for s in Setting do app.values[s] = SETTING_RANGE[s][2]
  app.shown = {.MINIMAP = true, .PERF = true, .TOASTS = true}
}

shutdown :: proc(app: ^App) {
  delete(app.toasts)
  ui.shutdown(&app.gui)
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

create_styles :: proc(app: ^App) {
  gui := &app.gui
  WHITE :: [4]u8{235, 235, 242, 255}
  GOLD :: [4]u8{236, 196, 104, 255}
  EDGE :: [4]u8{74, 80, 104, 255}
  s := &app.s
  s.text = ui.style_create(gui, {color = WHITE})
  s.dim = ui.style_create(gui, {color = rgba(160, 166, 184)})
  s.gold = ui.style_create(gui, {color = GOLD})
  s.good = ui.style_create(gui, {color = rgba(130, 220, 140)})
  s.title = ui.style_create(gui, {color = GOLD})
  s.small = ui.style_create(gui, {color = rgba(210, 214, 228)})
  s.panel = ui.style_create(gui, {fill = rgba(16, 18, 26, 215), border = 1, border_color = EDGE})
  s.window = ui.style_create(gui, {fill = rgba(20, 22, 32), border = 2, border_color = rgba(110, 92, 58)})
  s.title_bar = ui.style_create(gui, {fill = rgba(38, 34, 30), color = GOLD}, ui.Style{fill = rgba(48, 42, 34), color = GOLD})
  s.close = ui.style_create(gui, {color = rgba(200, 190, 170)}, ui.Style{fill = rgba(170, 50, 45), color = WHITE})
  button := ui.Style{fill = rgba(48, 54, 74), border = 1, border_color = rgba(88, 96, 124), color = WHITE}
  hover := button
  hover.fill, hover.border_color = rgba(66, 74, 100), GOLD
  press := button
  press.fill = rgba(34, 38, 52)
  active := button
  active.fill, active.border_color, active.color = rgba(132, 98, 44), GOLD, WHITE
  s.button = ui.style_create(gui, button, hover, press, active)
  tab := button
  tab.fill = rgba(30, 34, 46)
  s.tab = ui.style_create(gui, tab, hover, press, active)
  slot := ui.Style{fill = rgba(12, 14, 20, 230), border = 1, border_color = EDGE}
  slot_hover := slot
  slot_hover.border_color = GOLD
  slot_active := slot
  slot_active.fill = rgba(40, 34, 20, 230)
  s.slot = ui.style_create(gui, slot, slot_hover, slot_hover, slot_active)
  s.icon = ui.style_create(gui, {color = WHITE}, nil, nil, ui.Style{color = rgba(255, 255, 255, 70)})
  s.cooldown = ui.style_create(gui, {fill = rgba(0, 0, 0, 170), color = WHITE})
  s.bar = ui.style_create(gui, {fill = rgba(8, 8, 12, 200), border = 1, border_color = rgba(0, 0, 0, 255), color = WHITE})
  s.hp = ui.style_create(gui, {fill = rgba(196, 48, 52)})
  s.mp = ui.style_create(gui, {fill = rgba(52, 108, 220)})
  s.xp = ui.style_create(gui, {fill = rgba(160, 120, 236)})
  s.map_ = ui.style_create(gui, {fill = rgba(28, 52, 40, 225), border = 2, border_color = rgba(110, 92, 58)})
  s.enemy = ui.style_create(gui, {fill = rgba(230, 70, 60)})
  s.player = ui.style_create(gui, {fill = rgba(250, 230, 120)})
  s.tooltip = ui.style_create(gui, {fill = rgba(10, 10, 16), border = 1, border_color = rgba(130, 108, 66)})
  s.dim_screen = ui.style_create(gui, {fill = rgba(0, 0, 0, 150)})
  s.toast = ui.style_create(gui, {fill = rgba(10, 10, 16, 190), color = WHITE}, nil, nil, ui.Style{fill = rgba(10, 10, 16, 90), color = rgba(235, 235, 242, 110)})
  s.check = ui.style_create(gui, slot, slot_hover, slot_hover, ui.Style{fill = GOLD, border = 1, border_color = GOLD})
  s.track = ui.style_create(gui, {fill = rgba(10, 12, 18), border = 1, border_color = EDGE})
  s.track_fill = ui.style_create(gui, {fill = rgba(150, 112, 50)})
  s.knob = ui.style_create(gui, {fill = rgba(225, 225, 232), border = 1, border_color = rgba(0, 0, 0)}, ui.Style{fill = GOLD, border = 1, border_color = rgba(0, 0, 0)})
  row := ui.Style{color = WHITE}
  row_hover := ui.Style{fill = rgba(50, 54, 72), color = WHITE}
  row_active := ui.Style{fill = rgba(96, 74, 38), color = GOLD}
  s.row = ui.style_create(gui, row, row_hover, row_hover, row_active)
  s.row_text = ui.style_create(gui, {color = WHITE}, nil, nil, ui.Style{color = GOLD})
}

fixed :: proc(w, h: f32) -> [2]ui.Size {
  return {{.FIXED, w}, {.FIXED, h}}
}

add :: proc(app: ^App, parent: ui.NodeHandle, n: ui.Node) -> ui.NodeHandle {
  n := n
  n.parent = parent
  return ui.node_create(&app.gui, n)
}

label :: proc(app: ^App, parent: ui.NodeHandle, text: string, size: f32 = 16, style: ui.StyleHandle = 0, n: ui.Node = {}) -> ui.NodeHandle {
  n := n
  n.text, n.font_size, n.style = text, size, style if style != 0 else app.s.text
  return add(app, parent, n)
}

button :: proc(app: ^App, parent: ui.NodeHandle, text: string, width: f32 = 0, height: f32 = 34, style: ui.StyleHandle = 0) -> ui.NodeHandle {
  size := fixed(width, height) if width > 0 else [2]ui.Size{{}, {.FIXED, height}}
  b := add(app, parent, {size = size, padding = {14, 0, 14, 0}, align = {.CENTER, .CENTER}, interactive = true, style = style if style != 0 else app.s.button})
  label(app, b, text, 16)
  return b
}

tile_rect :: proc(tile: u32) -> ui.Rect {
  cell := 1 / SHEET
  return {{f32(tile % u32(SHEET.x)), f32(tile / u32(SHEET.x))} * cell, cell}
}

slot :: proc(app: ^App, parent: ui.NodeHandle, size: f32, key := "") -> Slot {
  s: Slot
  s.frame = add(app, parent, {size = fixed(size, size), padding = {6, 6, 6, 6}, interactive = true, style = app.s.slot})
  s.icon = add(app, s.frame, {size = {{.PERCENT, 1}, {.PERCENT, 1}}, style = app.s.icon, hidden = true, image = u32(app.sheet)})
  s.cooldown = add(app, s.frame, {position = .ABSOLUTE, anchor = {0, 1}, size = {{.PERCENT, 1}, {.PERCENT, 0}}, align = {.CENTER, .CENTER}, style = app.s.cooldown, hidden = true})
  s.count = label(app, s.frame, "", 13, app.s.text, {position = .ABSOLUTE, anchor = {1, 1}, offset = {-4, -2}})
  if key != "" do label(app, s.frame, key, 12, app.s.dim, {position = .ABSOLUTE, offset = {4, 2}})
  return s
}

bar :: proc(app: ^App, parent: ui.NodeHandle, width, height: f32, fill: ui.StyleHandle, font_size: f32 = 13) -> Bar {
  back := add(app, parent, {size = fixed(width, height), style = app.s.bar})
  b: Bar
  b.fill = add(app, back, {size = {{.PERCENT, 1}, {.PERCENT, 1}}, style = fill})
  if font_size > 0 do b.label = label(app, back, "", font_size, app.s.text, {position = .ABSOLUTE, anchor = {0.5, 0.5}})
  return b
}

build_hud :: proc(app: ^App) {
  s := &app.s
  screen := ui.node_create(&app.gui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}})

  frame := add(app, screen, {position = .ABSOLUTE, offset = {16, 16}, padding = {10, 10, 12, 10}, gap = 12, align = {.START, .CENTER}, style = s.panel})
  badge := add(app, frame, {size = fixed(56, 56), align = {.CENTER, .CENTER}, direction = .COLUMN, style = s.slot})
  label(app, badge, "LV", 11, s.dim)
  label(app, badge, "7", 24, s.gold)
  column := add(app, frame, {direction = .COLUMN, gap = 5})
  label(app, column, "Sir Aldric", 17, s.gold)
  set_bar(app, bar(app, column, 250, 18, s.hp), 240, 300)
  set_bar(app, bar(app, column, 250, 14, s.mp, 11), 90, 130)
  set_bar(app, bar(app, column, 250, 6, s.xp, 0), 140, 200)

  top_right := add(app, screen, {position = .ABSOLUTE, anchor = {1, 0}, offset = {-16, 16}, direction = .COLUMN, gap = 6, align = {.END, .START}})
  label(app, top_right, "Whispering Vale", 18, s.gold)
  app.map_frame = add(app, top_right, {size = fixed(176, 176), clip = true, style = s.map_})
  add(app, app.map_frame, {position = .ABSOLUTE, anchor = {0.5, 0.5}, size = fixed(10, 10), style = s.player, z = 1})
  for m in MAP_MARKERS do add(app, app.map_frame, {position = .ABSOLUTE, anchor = m, size = fixed(7, 7), style = s.enemy})
  gold := add(app, top_right, {gap = 6, align = {.END, .CENTER}, padding = {8, 4, 8, 4}, style = s.panel})
  add(app, gold, {size = fixed(18, 18), style = s.icon, image = u32(app.sheet), image_rect = tile_rect(151)})
  label(app, gold, "35", 16, s.gold)
  app.perf = label(app, top_right, "", 12, s.dim)

  tracker := add(app, screen, {position = .ABSOLUTE, anchor = {0, 0.4}, offset = {16, 0}, direction = .COLUMN, gap = 6, padding = {12, 10, 12, 10}, style = s.panel})
  label(app, tracker, "Quests", 16, s.gold)
  app.tracker = label(app, tracker, "", 14, s.small)

  hotbar := add(app, screen, {position = .ABSOLUTE, anchor = {0.5, 1}, offset = {0, -16}, gap = 6, padding = {8, 8, 8, 8}, style = s.panel})
  for &h, i in app.hotbar do h = slot(app, hotbar, 56, fmt.tprint(i + 1))

  menu := add(app, screen, {position = .ABSOLUTE, anchor = {1, 1}, offset = {-16, -16}, gap = 6, padding = {8, 8, 8, 8}, style = s.panel})
  for &b, m in app.menu {
    b = add(app, menu, {direction = .COLUMN, size = {{.FIXED, 62}, {.FIXED, 50}}, align = {.CENTER, .CENTER}, interactive = true, style = s.button})
    label(app, b, MENU_BUTTONS[m].label, 15)
    label(app, b, MENU_BUTTONS[m].key, 11, s.dim)
  }

  app.toast_list = add(app, screen, {position = .ABSOLUTE, anchor = {0.5, 1}, offset = {0, -110}, direction = .COLUMN, gap = 6, align = {.CENTER, .END}})

  app.tooltip = ui.node_create(&app.gui, {direction = .COLUMN, gap = 4, padding = {12, 10, 12, 10}, z = 5000, hidden = true, style = s.tooltip})
  app.tip_title = label(app, app.tooltip, "", 16, s.gold)
  app.tip_text = label(app, app.tooltip, "", 14, s.small, {size = {{.FIXED, 230}, {}}, wrap = true})
  app.ghost = ui.node_create(&app.gui, {size = fixed(44, 44), z = 6000, hidden = true, style = s.icon, image = u32(app.sheet)})
}

panel_create :: proc(app: ^App, w: Window, title: string, width: f32, offset: [2]f32) -> (body: ui.NodeHandle) {
  p := &app.panels[w]
  p.root = ui.node_create(&app.gui, {direction = .COLUMN, size = {{.FIXED, width}, {}}, offset = offset, interactive = true, hidden = true, style = app.s.window})
  bar := add(app, p.root, {size = {{.GROW, 0}, {.FIXED, 36}}, padding = {14, 0, 6, 0}, align = {.START, .CENTER}, interactive = true, style = app.s.title_bar})
  p.title = label(app, bar, title, 17, app.s.title)
  add(app, bar, {size = {{.GROW, 0}, {}}})
  p.close = add(app, bar, {size = fixed(26, 26), align = {.CENTER, .CENTER}, interactive = true, style = app.s.close})
  label(app, p.close, "x", 16)
  return add(app, p.root, {direction = .COLUMN, size = {{.GROW, 0}, {}}, padding = {16, 14, 16, 16}, gap = 12})
}

modal_create :: proc(app: ^App, w: Window, title: string) -> (body: ui.NodeHandle) {
  p := &app.panels[w]
  p.root = ui.node_create(&app.gui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}, align = {.CENTER, .CENTER}, interactive = true, hidden = true, style = app.s.dim_screen})
  box := add(app, p.root, {direction = .COLUMN, padding = {28, 22, 28, 24}, gap = 14, align = {.CENTER, .START}, style = app.s.window})
  p.title = label(app, box, title, 26, app.s.gold)
  return box
}

build_windows :: proc(app: ^App) {
  s := &app.s
  body := panel_create(app, .INVENTORY, "Inventory", 400, {700, 150})
  grid := add(app, body, {direction = .COLUMN, gap = 6})
  row: ui.NodeHandle
  for &b, i in app.bag_slots {
    if i % BAG_COLUMNS == 0 do row = add(app, grid, {gap = 6})
    b = slot(app, row, 56)
  }
  footer := add(app, body, {size = {{.GROW, 0}, {}}, gap = 8, align = {.START, .CENTER}})
  add(app, footer, {size = fixed(20, 20), style = s.icon, image = u32(app.sheet), image_rect = tile_rect(151)})
  label(app, footer, "35 gold", 16, s.gold)
  add(app, footer, {size = {{.GROW, 0}, {}}})
  app.sort = button(app, footer, "Sort")
  label(app, body, "Drag to move, drop on the hotbar to bind, right click to use.", 13, s.dim, {size = {{.GROW, 0}, {}}, wrap = true})

  body = panel_create(app, .CHARACTER, "Character", 330, {120, 140})
  label(app, body, "Knight, level 7", 15, s.small)
  app.points = label(app, body, "", 15, s.good)
  for stat in Stat {
    r := add(app, body, {size = {{.GROW, 0}, {.FIXED, 30}}, gap = 8, align = {.START, .CENTER}})
    label(app, r, fmt.tprintf("%v", stat), 15, s.text, {size = {{.FIXED, 120}, {}}})
    app.stat_value[stat] = label(app, r, "", 16, s.gold, {size = {{.GROW, 0}, {}}})
    app.stat_plus[stat] = button(app, r, "+", 30, 28)
  }

  body = panel_create(app, .QUESTS, "Quest Log", 560, {360, 120})
  split := add(app, body, {gap = 14, size = {{.GROW, 0}, {.FIXED, 300}}})
  app.quest_list = add(app, split, {direction = .COLUMN, size = {{.FIXED, 200}, {.GROW, 0}}, gap = 2, padding = {4, 4, 4, 4}, clip = true, interactive = true, style = s.track})
  for &r, i in app.quest_rows {
    r = add(app, app.quest_list, {size = {{.GROW, 0}, {.FIXED, 58}}, padding = {10, 0, 10, 0}, align = {.START, .CENTER}, interactive = true, style = s.row})
    label(app, r, QUESTS[i].title, 15, s.row_text)
  }
  detail := add(app, split, {direction = .COLUMN, size = {{.GROW, 0}, {.GROW, 0}}, gap = 10})
  app.quest_name = label(app, detail, "", 20, s.gold)
  app.quest_text = label(app, detail, "", 14, s.small, {size = {{.GROW, 0}, {}}, wrap = true})
  app.quest_goal = label(app, detail, "", 15, s.text)
  add(app, detail, {size = {{}, {.GROW, 0}}})
  app.track = add(app, detail, {size = fixed(120, 34), align = {.CENTER, .CENTER}, interactive = true, style = s.button})
  app.track_label = label(app, app.track, "Track", 16)

  body = panel_create(app, .SETTINGS, "Settings", 480, {400, 110})
  tabs := add(app, body, {gap = 4, size = {{.GROW, 0}, {}}})
  for &t, tab in app.tabs do t = button(app, tabs, tab_name(tab), 0, 32, s.tab)
  pages := add(app, body, {size = {{.GROW, 0}, {.FIXED, 250}}, padding = {14, 14, 14, 14}, style = s.track})
  for &p in app.pages do p = add(app, pages, {direction = .COLUMN, size = {{.GROW, 0}, {}}, gap = 12, hidden = true})
  slider_row(app, app.pages[.GAMEPLAY], .SENSITIVITY, "Camera speed")
  toggle_row(app, app.pages[.GAMEPLAY], .MINIMAP, "Show minimap  (M)")
  toggle_row(app, app.pages[.GAMEPLAY], .TOASTS, "Show messages")
  toggle_row(app, app.pages[.GAMEPLAY], .PERF, "Show UI statistics")
  slider_row(app, app.pages[.VIDEO], .FOV, "Field of view")
  slider_row(app, app.pages[.AUDIO], .MASTER, "Master volume")
  slider_row(app, app.pages[.AUDIO], .MUSIC, "Music")
  slider_row(app, app.pages[.AUDIO], .EFFECTS, "Effects")
  keys := add(app, app.pages[.CONTROLS], {gap = 24})
  label(app, keys, "1 - 8\nI\nC\nJ\nO\nM\nEsc\nLeft drag\nWheel\nRight click", 15, s.gold)
  label(app, keys, "Use hotbar slot\nInventory\nCharacter\nQuest log\nSettings\nMinimap\nMenu, close window\nOrbit camera\nZoom, scroll lists\nUse item", 15, s.small)
  buttons := add(app, body, {size = {{.GROW, 0}, {}}, align = {.END, .CENTER}})
  app.reset = button(app, buttons, "Reset defaults")

  body = modal_create(app, .PAUSE, "Paused")
  app.resume = button(app, body, "Resume", 220, 40)
  app.options = button(app, body, "Settings", 220, 40)
  app.quit = button(app, body, "Quit to desktop", 220, 40)

  body = modal_create(app, .CONFIRM, "Leave the vale?")
  label(app, body, "Unsaved progress will be lost.", 16, s.small)
  choice := add(app, body, {gap = 12})
  app.yes = button(app, choice, "Quit", 120, 38)
  app.no = button(app, choice, "Stay", 120, 38)
}

tab_name :: proc(t: Tab) -> string {
  switch t {
  case .GAMEPLAY:
    return "Gameplay"
  case .VIDEO:
    return "Video"
  case .AUDIO:
    return "Audio"
  case .CONTROLS:
    return "Controls"
  }
  return ""
}

slider_row :: proc(app: ^App, page: ui.NodeHandle, setting: Setting, text: string) {
  r := add(app, page, {size = {{.GROW, 0}, {.FIXED, 28}}, gap = 12, align = {.START, .CENTER}})
  label(app, r, text, 15, app.s.text, {size = {{.FIXED, 140}, {}}})
  sl := &app.sliders[setting]
  sl.track = add(app, r, {size = {{.GROW, 0}, {.FIXED, 10}}, interactive = true, style = app.s.track})
  sl.fill = add(app, sl.track, {size = {{.PERCENT, 0}, {.PERCENT, 1}}, style = app.s.track_fill})
  sl.knob = add(app, sl.track, {position = .ABSOLUTE, size = fixed(14, 22), anchor = {0, 0.5}, style = app.s.knob})
  sl.value = label(app, r, "", 15, app.s.gold, {size = {{.FIXED, 52}, {}}, align = {.END, .START}})
}

toggle_row :: proc(app: ^App, page: ui.NodeHandle, toggle: Toggle, text: string) {
  r := add(app, page, {size = {{.GROW, 0}, {.FIXED, 28}}, gap = 12, align = {.START, .CENTER}, interactive = true})
  app.toggles[toggle] = add(app, r, {size = fixed(22, 22), style = app.s.check})
  label(app, r, text, 15)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  ui.update_input(&app.gui, &app.input)
  handle_windows(app)
  handle_hud(app)
  handle_inventory(app)
  handle_panels(app)
  handle_keys(app)
  refresh(app, dt)
  camera := render.main_camera(&app.renderer)
  mjolnir.orbit_drag(&app.orbit, camera, &app.input, speed = 0.02 * app.values[.SENSITIVITY])
  if p, ok := &camera.projection.(render.PerspectiveProjection); ok do p.fov = math.to_radians(app.values[.FOV])
  start := time.tick_now()
  laid_out, painted := mjolnir.stage_ui(&app.renderer, &app.platform, &app.gui, &app.font)
  measure(app, time.tick_since(start), laid_out, painted, dt)
  mjolnir.update(&app.scene, &app.renderer, dt)
  gltf.animate(&app.hero, &app.knight, &app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return !app.quitting && mjolnir.frame(&app.platform, &app.renderer)
}

open_window :: proc(app: ^App, w: Window, open := true) {
  app.open[w] = open
  if !open do return
  app.top_z += 1
  ui.node(&app.gui, app.panels[w].root).z = app.top_z
}

topmost :: proc(app: ^App) -> (top: Window, ok: bool) {
  z := min(i32)
  for w in Window do if app.open[w] {
    if wz := ui.node(&app.gui, app.panels[w].root).z; wz > z {
      top, z, ok = w, wz, true
    }
  }
  return
}

handle_windows :: proc(app: ^App) {
  gui := &app.gui
  for &p, w in app.panels {
    if !app.open[w] do continue
    if input.mouse_pressed(&app.input, .LEFT) && ui.pressed(gui, p.root) do open_window(app, w)
    if p.close != {} && ui.clicked(gui, p.close) do app.open[w] = false
    if p.close != {} && ui.pressed(gui, ui.node(gui, p.close).parent) && !ui.pressed(gui, p.close) {
      ui.node(gui, p.root).offset += ui.to_reference(gui, app.input.mouse_delta)
    }
  }
}

handle_hud :: proc(app: ^App) {
  gui := &app.gui
  for b, m in app.menu do if ui.clicked(gui, b) {
    switch m {
    case .CHARACTER:
      open_window(app, .CHARACTER, !app.open[.CHARACTER])
    case .INVENTORY:
      open_window(app, .INVENTORY, !app.open[.INVENTORY])
    case .QUESTS:
      open_window(app, .QUESTS, !app.open[.QUESTS])
    case .SETTINGS:
      open_window(app, .SETTINGS, !app.open[.SETTINGS])
    case .MENU:
      open_window(app, .PAUSE)
    }
  }
  for h, i in app.hotbar do if ui.clicked(gui, h.frame) && input.mouse_released(&app.input, .LEFT) && app.dragging < 0 do use_action(app, i)
  for h, i in app.hotbar do if ui.clicked(gui, h.frame) && input.mouse_released(&app.input, .RIGHT) do app.actions[i] = nil
}

handle_inventory :: proc(app: ^App) {
  gui := &app.gui
  s := &app.input
  if app.open[.INVENTORY] && input.mouse_pressed(s, .LEFT) {
    for b, i in app.bag_slots do if ui.hovered(gui, b.frame) && app.bag[i].item != .NONE do app.dragging = i
  }
  if app.open[.INVENTORY] && input.mouse_released(s, .RIGHT) {
    for b, i in app.bag_slots do if ui.clicked(gui, b.frame) do use_item(app, app.bag[i].item)
  }
  if app.dragging < 0 || !input.mouse_released(s, .LEFT) do return
  from := app.dragging
  app.dragging = -1
  for b, i in app.bag_slots do if ui.hovered(gui, b.frame) && i != from {
    a, z := &app.bag[from], &app.bag[i]
    if a.item == z.item && z.count < ITEMS[z.item].stack {
      moved := min(a.count, ITEMS[z.item].stack - z.count)
      z.count += moved
      a.count -= moved
      if a.count == 0 do a^ = {}
    } else {
      a^, z^ = z^, a^
    }
  }
  for h, i in app.hotbar do if ui.hovered(gui, h.frame) {
    item := app.bag[from].item
    if ITEMS[item].consumable do app.actions[i] = item
    else do toast(app, fmt.tprintf("%s cannot be used from the hotbar", ITEMS[item].name))
  }
}

sort_bag :: proc(app: ^App) {
  for i in 0 ..< BAG_SIZE do for j in 0 ..< BAG_SIZE - 1 - i {
    a, b := app.bag[j], app.bag[j + 1]
    if a.item == .NONE && b.item != .NONE || a.item != .NONE && b.item != .NONE && a.item > b.item do app.bag[j], app.bag[j + 1] = b, a
  }
}

handle_panels :: proc(app: ^App) {
  gui := &app.gui
  if ui.clicked(gui, app.sort) do sort_bag(app)
  for stat in Stat do if ui.clicked(gui, app.stat_plus[stat]) && app.unspent > 0 {
    app.stats[stat] += 1
    app.unspent -= 1
  }
  for r, i in app.quest_rows do if ui.clicked(gui, r) do app.quest = i
  if ui.clicked(gui, app.track) do app.tracked[app.quest] = !app.tracked[app.quest]
  if ui.hovered(gui, app.quest_list) {
    list := ui.node(gui, app.quest_list)
    list.scroll.y = clamp(list.scroll.y - app.input.scroll.y * 24, 0, ui.max_scroll(gui, app.quest_list).y)
  }
  for t, tab in app.tabs do if ui.clicked(gui, t) do app.tab = tab
  for &sl, setting in app.sliders do if ui.pressed(gui, sl.track) {
    r := ui.rect(gui, sl.track)
    t := clamp((app.input.cursor.x - r.pos.x) / max(r.size.x, 1), 0, 1)
    lo, hi := SETTING_RANGE[setting][0], SETTING_RANGE[setting][1]
    app.values[setting] = lo + t * (hi - lo)
  }
  for t, toggle in app.toggles do if ui.clicked(gui, ui.node(gui, t).parent) do app.shown[toggle] = !app.shown[toggle]
  if ui.clicked(gui, app.reset) {
    for s in Setting do app.values[s] = SETTING_RANGE[s][2]
    app.shown = {.MINIMAP = true, .PERF = true, .TOASTS = true}
  }
  if ui.clicked(gui, app.resume) do app.open[.PAUSE] = false
  if ui.clicked(gui, app.options) do open_window(app, .SETTINGS)
  if ui.clicked(gui, app.quit) do open_window(app, .CONFIRM)
  if ui.clicked(gui, app.no) do app.open[.CONFIRM] = false
  if ui.clicked(gui, app.yes) do app.quitting = true
}

handle_keys :: proc(app: ^App) {
  s := &app.input
  if s.keyboard_captured do return
  if input.key_pressed(s, .ESCAPE) {
    if w, ok := topmost(app); ok do app.open[w] = false
    else do open_window(app, .PAUSE)
  }
  if app.open[.PAUSE] || app.open[.CONFIRM] do return
  toggles := [?]struct {
    key: input.Key,
    w:   Window,
  }{{.I, .INVENTORY}, {.C, .CHARACTER}, {.J, .QUESTS}, {.O, .SETTINGS}}
  for t in toggles do if input.key_pressed(s, t.key) do open_window(app, t.w, !app.open[t.w])
  if input.key_pressed(s, .M) do app.shown[.MINIMAP] = !app.shown[.MINIMAP]
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
  if !app.shown[.TOASTS] do return
  if len(app.toasts) == TOASTS {
    ui.destroy(&app.gui, app.toasts[0].node)
    ordered_remove(&app.toasts, 0)
  }
  node := label(app, app.toast_list, text, 15, app.s.toast, {padding = {12, 6, 12, 6}})
  append(&app.toasts, Toast{node, TOAST_SECONDS})
}

show :: proc(app: ^App, h: ui.NodeHandle, shown: bool) {
  ui.node(&app.gui, h).hidden = !shown
}

set_icon :: proc(app: ^App, s: Slot, tile: u32, shown: bool) {
  icon := ui.node(&app.gui, s.icon)
  icon.hidden = !shown
  icon.image_rect = tile_rect(tile)
}

set_bar :: proc(app: ^App, b: Bar, value, total: f32) {
  ui.node(&app.gui, b.fill).size.x = {.PERCENT, clamp(value / max(total, 1), 0, 1)}
  if b.label != {} do ui.set_text(&app.gui, b.label, fmt.tprintf("%.0f / %.0f", value, total))
}

refresh :: proc(app: ^App, dt: f32) {
  gui := &app.gui
  for w in Window do show(app, app.panels[w].root, app.open[w])
  show(app, app.map_frame, app.shown[.MINIMAP])
  show(app, app.perf, app.shown[.PERF])

  b := strings.builder_make(context.temp_allocator)
  for q, i in QUESTS do if app.tracked[i] do fmt.sbprintf(&b, "%s%s", "\n" if strings.builder_len(b) > 0 else "", q.title)
  ui.set_text(gui, app.tracker, strings.to_string(b) if strings.builder_len(b) > 0 else "No quests tracked")

  for h, i in app.hotbar {
    tile: u32
    count := ""
    total: f32 = 1
    switch a in app.actions[i] {
    case Skill:
      tile = SKILLS[a].tile
      total = SKILLS[a].cooldown
    case Item:
      tile = ITEMS[a].tile
      count = fmt.tprint(has(app, a))
    }
    set_icon(app, h, tile, app.actions[i] != nil)
    ui.set_text(gui, h.count, count)
    app.cooldowns[i] = max(app.cooldowns[i] - dt, 0)
    left := app.cooldowns[i]
    cooldown := ui.node(gui, h.cooldown)
    cooldown.hidden = left <= 0
    cooldown.size.y = {.PERCENT, math.ceil(left / total * 20) / 20}
  }
  for &t in app.toasts {
    t.life -= dt
    ui.node(gui, t.node).active = t.life < 1
  }
  for len(app.toasts) > 0 && app.toasts[0].life <= 0 {
    ui.destroy(gui, app.toasts[0].node)
    ordered_remove(&app.toasts, 0)
  }

  for b, i in app.bag_slots {
    stack := app.bag[i]
    set_icon(app, b, ITEMS[stack.item].tile, stack.item != .NONE)
    ui.node(gui, b.icon).active = i == app.dragging
    ui.set_text(gui, b.count, fmt.tprint(stack.count) if stack.count > 1 else "")
  }
  ghost := ui.node(gui, app.ghost)
  ghost.hidden = app.dragging < 0
  if app.dragging >= 0 {
    ghost.image_rect = tile_rect(ITEMS[app.bag[app.dragging].item].tile)
    ghost.offset = ui.to_reference(gui, app.input.cursor) - 22
  }

  ui.set_text(gui, app.points, fmt.tprintf("%d attribute points to spend", app.unspent) if app.unspent > 0 else "")
  for stat in Stat {
    ui.set_text(gui, app.stat_value[stat], fmt.tprint(app.stats[stat]))
    show(app, app.stat_plus[stat], app.unspent > 0)
  }

  for r, i in app.quest_rows do ui.node(gui, r).active = i == app.quest
  q := QUESTS[app.quest]
  ui.set_text(gui, app.quest_name, q.title)
  ui.set_text(gui, app.quest_text, q.text)
  ui.set_text(gui, app.quest_goal, q.goal)
  ui.set_text(gui, app.track_label, "Untrack" if app.tracked[app.quest] else "Track")

  for t, tab in app.tabs do ui.node(gui, t).active = tab == app.tab
  for p, tab in app.pages do show(app, p, tab == app.tab)
  for sl, setting in app.sliders {
    lo, hi := SETTING_RANGE[setting][0], SETTING_RANGE[setting][1]
    t := (app.values[setting] - lo) / (hi - lo)
    ui.node(gui, sl.fill).size.x = {.PERCENT, t}
    ui.node(gui, sl.knob).anchor = {t, 0.5}
    format := "%.0f" if hi > 10 else "%.2f"
    ui.set_text(gui, sl.value, fmt.tprintf(format, app.values[setting]))
  }
  for t, toggle in app.toggles do ui.node(gui, t).active = app.shown[toggle]

  tooltip(app)
}

tooltip :: proc(app: ^App) {
  gui := &app.gui
  title, text := "", ""
  if app.dragging < 0 {
    for b, i in app.bag_slots do if app.open[.INVENTORY] && ui.hovered(gui, b.frame) && app.bag[i].item != .NONE {
      info := ITEMS[app.bag[i].item]
      title = info.name
      text = fmt.tprintf("%s\nWorth %d gold%s", info.text, info.value, "\nRight click to use" if info.consumable else "")
    }
  }
  tip := ui.node(gui, app.tooltip)
  tip.hidden = title == ""
  if tip.hidden do return
  ui.set_text(gui, app.tip_title, title)
  ui.set_text(gui, app.tip_text, text)
  size := ui.to_reference(gui, ui.rect(gui, app.tooltip).size)
  screen := ui.to_reference(gui, render.window_size(&app.renderer))
  at := ui.to_reference(gui, app.input.cursor) + 18
  tip.offset = {min(at.x, screen.x - size.x - 8), min(at.y, screen.y - size.y - 8)}
}

measure :: proc(app: ^App, cost: time.Duration, laid_out, painted: bool, dt: f32) {
  app.frames += 1
  app.ui_time += cost
  if laid_out do app.layouts += 1
  if painted do app.paints += 1
  app.perf_tick += dt
  if app.perf_tick < 0.5 do return
  ui.set_text(
    &app.gui,
    app.perf,
    fmt.tprintf("UI %d nodes  %d layouts  %d paints of %d frames  %.0f us/frame", len(app.gui.draw_order), app.layouts, app.paints, app.frames, time.duration_microseconds(app.ui_time) / f64(app.frames)),
  )
  app.perf_tick, app.frames, app.layouts, app.paints, app.ui_time = 0, 0, 0, 0, 0
}
