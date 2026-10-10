package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
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
  defer mjolnir.gltf_scene_destroy(&character)
  mjolnir.run_app(
    {
      title = "Level Management",
      width = 1100,
      height = 760,
      debug_ui = true,
      setup = setup,
      update = update,
      pre_render = panel,
    },
  )
}

setup :: proc(engine: ^mjolnir.Engine) {
  clear(&example_materials)
  clear(&example_meshes)
  clear(&example_nodes)
  clear(&gltf_roots)
  for &a in animators do anim.animator_destroy(&a)
  clear(&animators)
  mjolnir.gltf_scene_destroy(&character)

  half := f32(GRID - 1) * 0.5 * SPACING
  render.main_camera_look_at(&engine.render, {half + 4, half + 6, half * 2.4}, {0, half - 1, 0})
  mjolnir.spawn(engine, {-6, 14, 6}, render.directional_light_attachment({1, 0.96, 0.9, 1}, 8.0))

  // Ground uses BUILTIN mesh + material: stays put through every destroy button.
  ground := mjolnir.spawn(
    engine,
    {0, -1, 0},
    render.MeshAttachment {
      handle = render.get_builtin_mesh(&engine.render, .QUAD_XZ),
      material = render.get_builtin_material(&engine.render, .GRAY),
      cast_shadow = false,
    },
  )
  world.scale(&engine.world, ground, f32(GRID) * SPACING * 1.5)

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
    m, ok := render.create_mesh(&engine.render, geom, true)
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
      &engine.render,
      type = .PBR,
      base_color_factor = color,
      metallic_value = t,
      roughness_value = 1.0 - t,
    )
    if !ok do continue
    append(&example_materials, mat)
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING
    node, node_ok := mjolnir.spawn(
      engine,
      {x, y, 0},
      render.MeshAttachment{handle = col_meshes[col], material = mat, cast_shadow = true},
    )
    if node_ok do append(&example_nodes, node)
  }

  // glTF models join the mix. Their loader-created meshes/materials land in the
  // same render pools, so fold them into the tracked lists — the destroy buttons
  // then free them exactly like the grid resources, and reset rebuilds them.
  if duck, ok := mjolnir.load_gltf(engine, "assets/Duck.glb"); ok {
    defer mjolnir.gltf_scene_destroy(&duck)
    for h in duck.roots {
      world.scale(&engine.world, h, 1.3)
      world.translate(&engine.world, h, -3.5, 0, 4.5)
      append(&gltf_roots, h)
    }
    collect_gltf_resources(engine, duck.roots[:])
  }
  if scene, ok := mjolnir.load_gltf(engine, "assets/CesiumMan.glb"); ok {
    character = scene
    for h in character.roots {
      world.scale(&engine.world, h, 6.0)
      world.translate(&engine.world, h, 3.5, 0, 4.5)
      append(&gltf_roots, h)
    }
    for s in character.skinned {
      rig := &character.rigs[s.rig]
      a: anim.Animator
      anim.animator_init(&a, rig)
      anim.play(&a, rig, "Anim_0")
      append(&animators, a)
    }
    collect_gltf_resources(engine, character.roots[:])
  }

  log.infof(
    "level setup: %d materials, %d meshes, %d nodes (reset #%d)",
    len(example_materials),
    len(example_meshes),
    len(example_nodes),
    reset_count,
  )
}

collect_gltf_resources :: proc(engine: ^mjolnir.Engine, roots: []world.NodeHandle) {
  seen_mesh := make(map[render.MeshHandle]bool, 16, context.temp_allocator)
  seen_mat := make(map[render.MaterialHandle]bool, 16, context.temp_allocator)
  stack := make([dynamic]world.NodeHandle, context.temp_allocator)
  append(&stack, ..roots)
  for len(stack) > 0 {
    h := pop(&stack)
    n := world.node(&engine.world, h) or_continue
    append(&stack, ..n.children[:])
    att := render.attachment(&engine.render, h.index, render.MeshAttachment) or_continue
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

act_destroy_materials :: proc(engine: ^mjolnir.Engine) {
  if len(example_materials) == 0 do return
  default_mat := render.get_builtin_material(&engine.render, .GRAY)
  for h in example_nodes {
    if a, ok := render.attachment(&engine.render, h.index, render.MeshAttachment); ok {
      a.material = default_mat
      render.mark_slot_dirty(&engine.render, h.index)
    }
  }
  freed := len(example_materials)
  for m in example_materials {
    render.destroy_material(&engine.render, m)
  }
  clear(&example_materials)
  log.infof("destroyed %d materials -> builtin GRAY", freed)
}

act_destroy_meshes :: proc(engine: ^mjolnir.Engine) {
  if len(example_meshes) == 0 do return
  cube := render.get_builtin_mesh(&engine.render, .CUBE)
  for h in example_nodes {
    if a, ok := render.attachment(&engine.render, h.index, render.MeshAttachment); ok {
      a.handle = cube
      render.mark_slot_dirty(&engine.render, h.index)
    }
  }
  freed := len(example_meshes)
  for m in example_meshes {
    render.destroy_mesh(&engine.render, m)
  }
  clear(&example_meshes)
  log.infof("destroyed %d meshes -> builtin CUBE", freed)
}

act_reset_level :: proc(engine: ^mjolnir.Engine) {
  for m in example_materials do render.destroy_material(&engine.render, m)
  for m in example_meshes do render.destroy_mesh(&engine.render, m)
  clear(&example_materials)
  clear(&example_meshes)
  clear(&example_nodes)
  reset_count += 1
  // Teardown + setup run at the start of the next update.
  reset_requested = true
  log.infof("level reset scheduled (#%d)", reset_count)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if reset_requested {
    reset_requested = false
    mjolnir.teardown(engine)
    mjolnir.setup(engine)
    return
  }
  for h in gltf_roots do world.rotate_by(&engine.world, h, delta_time * math.PI * 0.3)
  for s, i in character.skinned do anim.animator_update(&animators[i], &character.rigs[s.rig], delta_time)
  when AUTOMATED_TEST {
	  test_frame += 1
	  switch test_frame {
	  case 5:
	    act_destroy_materials(engine)
	  case 10:
	    act_destroy_meshes(engine)
	  case 15:
	    act_reset_level(engine)
	  case 22:
	    act_destroy_materials(engine)
	  case 27:
	    act_destroy_meshes(engine)
	  case 32:
	    act_reset_level(engine)
	  case 40:
	    log.info("automated test sequence complete")
	  }
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
  for s, i in character.skinned do render.stage_bones(&engine.render, s.node.index, animators[i].palette)
}

panel :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Level Management", {20, 20, 320, 260}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Example materials: %d", len(example_materials)))
    mu.label(ctx, fmt.tprintf("Example meshes:    %d", len(example_meshes)))
    mu.label(ctx, fmt.tprintf("Resets:            %d", reset_count))
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "Destroy All Materials") {
      act_destroy_materials(engine)
    }
    if .SUBMIT in mu.button(ctx, "Destroy All Meshes") {
      act_destroy_meshes(engine)
    }
    if .SUBMIT in mu.button(ctx, "Reset Level") {
      act_reset_level(engine)
    }
  }
}
