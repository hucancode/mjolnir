package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render/mesh"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

AUTOMATED_TEST :: #config(AUTOMATED_TEST, false)

GRID :: 5
SPACING :: 2.5

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
}

example_materials: [dynamic]render.MaterialHandle
example_meshes: [dynamic]render.MeshHandle
example_nodes: [dynamic]world.NodeHandle // mesh-bearing nodes we may reassign
gltf_roots: [dynamic]world.NodeHandle // duck + animated char roots, spun in update
character: mjolnir.GltfScene
animators: [dynamic]anim.Animator // one per character.skinned entry

reset_count: int
reset_requested: bool
test_frame: int

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1100, 760, "Level Management") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Level Management", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = render.orbit_controller()
  defer mjolnir.gltf_scene_destroy(&character)
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  panel(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

setup :: proc(app: ^App) {
  clear(&example_materials)
  clear(&example_meshes)
  clear(&example_nodes)
  clear(&gltf_roots)
  for &a in animators do anim.animator_destroy(&a)
  clear(&animators)
  mjolnir.gltf_scene_destroy(&character)

  half := f32(GRID - 1) * 0.5 * SPACING
  render.main_camera_look_at(&app.renderer, {half + 4, half + 6, half * 2.4}, {0, half - 1, 0})
  light := world.spawn(&app.scene, {-6, 14, 6})
  render.attach(&app.renderer, light.index, render.directional_light_attachment({1, 0.96, 0.9, 1}, 8.0))

  // Ground uses BUILTIN mesh + material: stays put through every destroy button.
  ground := world.spawn(&app.scene, {0, -1, 0})
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, f32(GRID) * SPACING * 1.5)

  // One example mesh per column (distinct primitive), so "Destroy All Meshes" is
  // visible: every column collapses to the builtin cube.
  primitives := [GRID]mesh.Geometry {
    mesh.make_sphere(),
    mesh.make_cone(),
    mesh.make_capsule(),
    mesh.make_cylinder(),
    mesh.make_torus(),
  }
  col_meshes: [GRID]render.MeshHandle
  for geom, col in primitives {
    m, ok := render.create_mesh(&app.renderer, geom, true)
    if !ok do continue
    col_meshes[col] = m
    append(&example_meshes, m)
  }

  // One example material per cell (varied color + roughness), so "Destroy All
  // Materials" recolors the whole grid to the builtin default at once.
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    t := f32(row) / f32(GRID - 1)
    color := [4]f32{0.2 + 0.8 * f32(col) / f32(GRID - 1), 0.3, 1.0 - 0.8 * t, 1.0}
    mat, ok := render.create_material(
      &app.renderer,
      type = .PBR,
      base_color_factor = color,
      metallic_value = t,
      roughness_value = 1.0 - t,
    )
    if !ok do continue
    append(&example_materials, mat)
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING
    node, node_ok := world.spawn(&app.scene, {x, y, 0})
    if !node_ok do continue
    render.attach(&app.renderer, node.index, render.MeshAttachment{handle = col_meshes[col], material = mat, cast_shadow = true})
    append(&example_nodes, node)
  }

  // glTF models join the mix. Their loader-created meshes/materials land in the
  // same render pools, so fold them into the tracked lists — the destroy buttons
  // then free them exactly like the grid resources, and reset rebuilds them.
  if duck, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/Duck.glb"); ok {
    defer mjolnir.gltf_scene_destroy(&duck)
    for h in duck.roots {
      world.scale(&app.scene, h, 1.3)
      world.translate(&app.scene, h, -3.5, 0, 4.5)
      append(&gltf_roots, h)
    }
    collect_gltf_resources(app, duck.roots[:])
  }
  if scene, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/CesiumMan.glb"); ok {
    character = scene
    for h in character.roots {
      world.scale(&app.scene, h, 6.0)
      world.translate(&app.scene, h, 3.5, 0, 4.5)
      append(&gltf_roots, h)
    }
    for s in character.skinned {
      rig := &character.rigs[s.rig]
      a: anim.Animator
      anim.animator_init(&a, rig)
      anim.play(&a, rig, "Anim_0")
      append(&animators, a)
    }
    collect_gltf_resources(app, character.roots[:])
  }

  log.infof(
    "level setup: %d materials, %d meshes, %d nodes (reset #%d)",
    len(example_materials),
    len(example_meshes),
    len(example_nodes),
    reset_count,
  )
}

collect_gltf_resources :: proc(app: ^App, roots: []world.NodeHandle) {
  seen_mesh := make(map[render.MeshHandle]bool, 16, context.temp_allocator)
  seen_mat := make(map[render.MaterialHandle]bool, 16, context.temp_allocator)
  stack := make([dynamic]world.NodeHandle, context.temp_allocator)
  append(&stack, ..roots)
  for len(stack) > 0 {
    h := pop(&stack)
    n := world.node(&app.scene, h) or_continue
    append(&stack, ..n.children[:])
    att := render.attachment(&app.renderer, h.index, render.MeshAttachment) or_continue
    append(&example_nodes, h)
    if att.handle not_in seen_mesh {
      seen_mesh[att.handle] = true
      append(&example_meshes, att.handle)
    }
    if att.material not_in seen_mat {
      seen_mat[att.material] = true
      append(&example_materials, att.material)
    }
  }
}

act_destroy_materials :: proc(app: ^App) {
  if len(example_materials) == 0 do return
  default_mat := app.renderer.builtin_materials[.GRAY]
  for h in example_nodes {
    if a, ok := render.attachment(&app.renderer, h.index, render.MeshAttachment); ok {
      a.material = default_mat
      render.mark_slot_dirty(&app.renderer, h.index)
    }
  }
  freed := len(example_materials)
  for m in example_materials {
    render.destroy_material(&app.renderer, m)
  }
  clear(&example_materials)
  log.infof("destroyed %d materials -> builtin GRAY", freed)
}

act_destroy_meshes :: proc(app: ^App) {
  if len(example_meshes) == 0 do return
  cube := app.renderer.builtin_meshes[.CUBE]
  for h in example_nodes {
    if a, ok := render.attachment(&app.renderer, h.index, render.MeshAttachment); ok {
      a.handle = cube
      render.mark_slot_dirty(&app.renderer, h.index)
    }
  }
  freed := len(example_meshes)
  for m in example_meshes {
    render.destroy_mesh(&app.renderer, m)
  }
  clear(&example_meshes)
  log.infof("destroyed %d meshes -> builtin CUBE", freed)
}

act_reset_level :: proc(app: ^App) {
  for m in example_materials do render.destroy_material(&app.renderer, m)
  for m in example_meshes do render.destroy_mesh(&app.renderer, m)
  clear(&example_materials)
  clear(&example_meshes)
  clear(&example_nodes)
  reset_count += 1
  // Teardown + setup run at the start of the next update.
  reset_requested = true
  log.infof("level reset scheduled (#%d)", reset_count)
}

update :: proc(app: ^App, delta_time: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, delta_time)
  if reset_requested {
    reset_requested = false
    world.teardown(&app.scene)
    render.teardown(&app.renderer)
    if render.setup(&app.renderer) {
      render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
      setup(app)
    }
    render.update(&app.renderer, delta_time)
    return
  }
  for h in gltf_roots do world.rotate_by(&app.scene, h, delta_time * math.PI * 0.3)
  for s, i in character.skinned do anim.animator_update(&animators[i], &character.rigs[s.rig], delta_time)
  when AUTOMATED_TEST {
	  test_frame += 1
	  switch test_frame {
	  case 5:
	    act_destroy_materials(app)
	  case 10:
	    act_destroy_meshes(app)
	  case 15:
	    act_reset_level(app)
	  case 22:
	    act_destroy_materials(app)
	  case 27:
	    act_destroy_meshes(app)
	  case 32:
	    act_reset_level(app)
	  case 40:
	    log.info("automated test sequence complete")
	  }
  }
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  for s, i in character.skinned do render.stage_bones(&app.renderer, s.node.index, animators[i].palette)
  render.update(&app.renderer, delta_time)
}

panel :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Level Management", {20, 20, 320, 260}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Example materials: %d", len(example_materials)))
    mu.label(ctx, fmt.tprintf("Example meshes:    %d", len(example_meshes)))
    mu.label(ctx, fmt.tprintf("Resets:            %d", reset_count))
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "Destroy All Materials") {
      act_destroy_materials(app)
    }
    if .SUBMIT in mu.button(ctx, "Destroy All Meshes") {
      act_destroy_meshes(app)
    }
    if .SUBMIT in mu.button(ctx, "Reset Level") {
      act_reset_level(app)
    }
  }
}
