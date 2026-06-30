package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

AUTOMATED_TEST :: #config(AUTOMATED_TEST, false)

GRID :: 5
SPACING :: 2.5

example_materials: [dynamic]world.MaterialHandle
example_meshes: [dynamic]world.MeshHandle
example_nodes: [dynamic]world.NodeHandle // mesh-bearing nodes we may reassign
gltf_roots: [dynamic]world.NodeHandle // duck + animated char roots, spun in update

reset_count: int
test_frame: int

main :: proc() {
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

  half := f32(GRID - 1) * 0.5 * SPACING
  world.main_camera_look_at(&engine.world, {half + 4, half + 6, half * 2.4}, {0, half - 1, 0})
  world.spawn_light_directional(&engine.world, {-6, 14, 6}, {1, 0.96, 0.9, 1}, 8.0)

  // Ground uses BUILTIN mesh + material: stays put through every destroy button.
  ground := world.spawn(
    &engine.world,
    {0, -1, 0},
    world.MeshAttachment {
      handle = world.get_builtin_mesh(&engine.world, .QUAD_XZ),
      material = world.get_builtin_material(&engine.world, .GRAY),
      cast_shadow = false,
    },
  )
  world.scale(&engine.world, ground, f32(GRID) * SPACING * 1.5)

  // One example mesh per column (distinct primitive), so "Destroy All Meshes" is
  // visible: every column collapses to the builtin cube.
  primitives := [GRID]geometry.Geometry {
    geometry.make_sphere(),
    geometry.make_cone(),
    geometry.make_capsule(),
    geometry.make_cylinder(),
    geometry.make_torus(),
  }
  col_meshes: [GRID]world.MeshHandle
  for geom, col in primitives {
    m, ok := world.create_mesh(&engine.world, geom, true)
    if !ok do continue
    col_meshes[col] = m
    append(&example_meshes, m)
  }

  // One example material per cell (varied color + roughness), so "Destroy All
  // Materials" recolors the whole grid to the builtin default at once.
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    t := f32(row) / f32(GRID - 1)
    color := [4]f32{0.2 + 0.8 * f32(col) / f32(GRID - 1), 0.3, 1.0 - 0.8 * t, 1.0}
    mat, ok := world.create_material(
      &engine.world,
      type = .PBR,
      base_color_factor = color,
      metallic_value = t,
      roughness_value = 1.0 - t,
    )
    if !ok do continue
    append(&example_materials, mat)
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING
    node, node_ok := world.spawn(
      &engine.world,
      {x, y, 0},
      world.MeshAttachment{handle = col_meshes[col], material = mat, cast_shadow = true},
    )
    if node_ok do append(&example_nodes, node)
  }

  // glTF models join the mix. Their loader-created meshes/materials land in the
  // same world pools, so fold them into the tracked lists — the destroy buttons
  // then free them exactly like the grid resources, and reset rebuilds them.
  if duck, ok := mjolnir.load_gltf(engine, "assets/Duck.glb"); ok {
    for h in duck {
      world.scale(&engine.world, h, 1.3)
      world.translate(&engine.world, h, -3.5, 0, 4.5)
      append(&gltf_roots, h)
    }
    collect_gltf_resources(&engine.world, duck[:])
  }
  if char, ok := mjolnir.load_gltf(engine, "assets/CesiumMan.glb"); ok {
    for h in char {
      world.scale(&engine.world, h, 6.0)
      world.translate(&engine.world, h, 3.5, 0, 4.5)
      append(&gltf_roots, h)
      node := world.node(&engine.world, h) or_continue
      for c in node.children do if world.play_animation(&engine.world, c, "Anim_0") do break
    }
    collect_gltf_resources(&engine.world, char[:])
  }

  log.infof(
    "level setup: %d materials, %d meshes, %d nodes (reset #%d)",
    len(example_materials),
    len(example_meshes),
    len(example_nodes),
    reset_count,
  )
}

collect_gltf_resources :: proc(w: ^world.World, roots: []world.NodeHandle) {
  seen_mesh := make(map[world.MeshHandle]bool, 16, context.temp_allocator)
  seen_mat := make(map[world.MaterialHandle]bool, 16, context.temp_allocator)
  stack := make([dynamic]world.NodeHandle, context.temp_allocator)
  append(&stack, ..roots)
  for len(stack) > 0 {
    h := pop(&stack)
    n := world.node(w, h) or_continue
    append(&stack, ..n.children[:])
    att := world.mesh_attachment(w, h) or_continue
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
  default_mat := world.get_builtin_material(&engine.world, .GRAY)
  for h in example_nodes {
    world.set_material_handle(&engine.world, h, default_mat)
  }
  freed := len(example_materials)
  for m in example_materials {
    world.destroy_material(&engine.world, m)
  }
  clear(&example_materials)
  log.infof("destroyed %d materials -> builtin GRAY", freed)
}

act_destroy_meshes :: proc(engine: ^mjolnir.Engine) {
  if len(example_meshes) == 0 do return
  cube := world.get_builtin_mesh(&engine.world, .CUBE)
  for h in example_nodes {
    world.set_mesh_handle(&engine.world, h, cube)
  }
  freed := len(example_meshes)
  for m in example_meshes {
    world.destroy_mesh(&engine.world, m)
  }
  clear(&example_meshes)
  log.infof("destroyed %d meshes -> builtin CUBE", freed)
}

act_reset_level :: proc(engine: ^mjolnir.Engine) {
  for m in example_materials do world.destroy_material(&engine.world, m)
  for m in example_meshes do world.destroy_mesh(&engine.world, m)
  clear(&example_materials)
  clear(&example_meshes)
  clear(&example_nodes)
  reset_count += 1
  mjolnir.schedule_teardown(engine)
  mjolnir.schedule_setup(engine)
  log.infof("level reset scheduled (#%d)", reset_count)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  for h in gltf_roots do world.rotate_by(&engine.world, h, delta_time * math.PI * 0.3)
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
}

panel :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
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
