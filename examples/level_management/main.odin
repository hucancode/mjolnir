// Destroying resources and reloading a level.
package main

import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"
import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/debugui"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

AUTOMATED_TEST :: #config(AUTOMATED_TEST, false)

GRID :: 5
SPACING :: 2.5

Cell :: struct {
  node: world.NodeHandle,
  look: render.MeshAttachment,
}

App :: struct {
  window:          platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  cells:           [dynamic]Cell,
  meshes:          [dynamic]render.MeshHandle,
  materials:       [dynamic]render.MaterialHandle,
  duck:            gltf.Scene,
  character:       gltf.Scene,
  animators:       [dynamic]anim.Animator,
  resets:          int,
  reset_requested: bool,
  test_frame:      int,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1100, 760, "Level Management") do return
  if !render.init(&app.renderer, "Level Management", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  panel(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  render.setup(&app.renderer)
  build_level(app)
  return .READY
}

build_level :: proc(app: ^App) {
  half := f32(GRID - 1) * 0.5 * SPACING
  render.camera_look_at(render.main_camera(&app.renderer), {half + 4, half + 6, half * 2.4}, {0, half - 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, half - 1, 0})
  light := world.spawn(&app.scene, {-6, 14, 6})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.96, 0.9}, 1, 8.0)))

  ground := world.spawn(&app.scene, {0, -1, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, f32(GRID) * SPACING * 1.5)

  column_shapes := [GRID]render.Geometry{render.make_sphere(), render.make_cone(), render.make_capsule(), render.make_cylinder(), render.make_torus()}
  column_meshes: [GRID]render.MeshHandle
  for shape, col in column_shapes {
    column_meshes[col] = render.mesh_create(&app.renderer, shape) or_continue
    append(&app.meshes, column_meshes[col])
  }
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    t := f32(row) / f32(GRID - 1)
    color := [4]f32{0.2 + 0.8 * f32(col) / f32(GRID - 1), 0.3, 1.0 - 0.8 * t, 1.0}
    material := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = color, metallic_value = t, roughness_value = 1.0 - t)) or_continue
    append(&app.materials, material)
    node := world.spawn(&app.scene, {f32(col) * SPACING - half, f32(row) * SPACING, 0}) or_continue
    cell := Cell{node = node, look = {mesh = column_meshes[col], material = material, cast_shadow = true}}
    render.attach(&app.renderer, render.SlotHandle(node.index), cell.look)
    append(&app.cells, cell)
  }

  app.duck = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/Duck.glb"))
  for h in app.duck.roots {
    world.scale(&app.scene, h, 1.3)
    world.translate(&app.scene, h, -3.5, 0, 4.5)
  }
  app.character = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/CesiumMan.glb"))
  for h in app.character.roots {
    world.scale(&app.scene, h, 6.0)
    world.translate(&app.scene, h, 3.5, 0, 4.5)
  }
  for s in app.character.skinned {
    rig := &app.character.rigs[s.rig]
    a: anim.Animator
    anim.animator_init(&a, rig)
    anim.play(&a, rig, "Anim_0")
    append(&app.animators, a)
  }
  log.infof("level built: %d materials, %d meshes (reset #%d)", len(app.materials), len(app.meshes), app.resets)
}

destroy_level :: proc(app: ^App) {
  for &a in app.animators do anim.destroy(&a)
  clear(&app.animators)
  gltf.destroy(&app.duck, &app.scene, &app.renderer)
  gltf.destroy(&app.character, &app.scene, &app.renderer)
  clear(&app.cells)
  clear(&app.meshes)
  clear(&app.materials)
  world.teardown(&app.scene)
  render.teardown(&app.renderer)
}

shutdown :: proc(app: ^App) {
  destroy_level(app)
  delete(app.animators)
  delete(app.cells)
  delete(app.meshes)
  delete(app.materials)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

destroy_materials :: proc(app: ^App) {
  for &cell in app.cells {
    cell.look.material = app.renderer.builtin_materials[.GRAY]
    render.attach(&app.renderer, render.SlotHandle(cell.node.index), cell.look)
  }
  for m in app.materials do render.destroy(&app.renderer, m)
  log.infof("destroyed %d materials -> builtin GRAY", len(app.materials))
  clear(&app.materials)
}

destroy_meshes :: proc(app: ^App) {
  for &cell in app.cells {
    cell.look.mesh = app.renderer.builtin_meshes[.CUBE]
    render.attach(&app.renderer, render.SlotHandle(cell.node.index), cell.look)
  }
  for m in app.meshes do render.destroy(&app.renderer, m)
  log.infof("destroyed %d meshes -> builtin CUBE", len(app.meshes))
  clear(&app.meshes)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  if app.reset_requested {
    app.reset_requested = false
    app.resets += 1
    destroy_level(app)
    build_level(app)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  for h in app.duck.roots do world.rotate_by(&app.scene, h, dt * math.PI * 0.3)
  for h in app.character.roots do world.rotate_by(&app.scene, h, dt * math.PI * 0.3)
  for s, i in app.character.skinned do anim.animator_update(&app.animators[i], &app.character.rigs[s.rig], dt)
  when AUTOMATED_TEST do run_test_step(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for s, i in app.character.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), app.animators[i].palette)
  render.update(&app.renderer, dt)
}

run_test_step :: proc(app: ^App) {
  app.test_frame += 1
  switch app.test_frame {
  case 5, 22:
    destroy_materials(app)
  case 10, 27:
    destroy_meshes(app)
  case 15, 32:
    app.reset_requested = true
  case 40:
    log.info("automated test sequence complete")
  }
}

panel :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Level Management", {20, 20, 320, 260}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Grid materials: %d", len(app.materials)))
    mu.label(ctx, fmt.tprintf("Grid meshes:    %d", len(app.meshes)))
    mu.label(ctx, fmt.tprintf("Resets:         %d", app.resets))
    if .SUBMIT in mu.button(ctx, "Destroy All Materials") do destroy_materials(app)
    if .SUBMIT in mu.button(ctx, "Destroy All Meshes") do destroy_meshes(app)
    if .SUBMIT in mu.button(ctx, "Reset Level") do app.reset_requested = true
  }
}
