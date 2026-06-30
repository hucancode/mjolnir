package scene_sync

import cont "../containers"
import "../gpu"
import "../render"
import ui_render "../render/ui"
import ui_module "../ui"
import "../world"
import "core:sync"
import vk "vendor:vulkan"

@(private = "file")
age_and_mark :: proc(
  m: ^$M/map[$H]world.StagingEntry,
  handle: H,
  prev_age: u16,
  stale: ^[dynamic]H,
) {
  new_age := prev_age + 1
  m^[handle] = {new_age, .Update}
  if int(new_age) >= world.FRAMES_IN_FLIGHT do append(stale, handle)
}

@(private = "file")
material_type_flags :: proc(t: world.MaterialType) -> render.NodeFlagSet {
  switch t {
  case .TRANSPARENT:  return {.MATERIAL_TRANSPARENT}
  case .WIREFRAME:    return {.MATERIAL_WIREFRAME}
  case .RANDOM_COLOR: return {.MATERIAL_RANDOM_COLOR}
  case .LINE_STRIP:   return {.MATERIAL_LINE_STRIP}
  case .PBR, .UNLIT:  return {}
  }
  return {}
}

@(private = "file")
fill_mesh_node_data :: proc(
  rndr: ^render.Manager,
  wld: ^world.World,
  node: ^world.Node,
  att: world.MeshAttachment,
  handle_index: u32,
  nd: ^render.Node,
) {
  if skin, has_skin := att.skinning.?; has_skin {
    nd.attachment_data_index = render.ensure_bone_matrix_range_for_node(
      rndr,
      handle_index,
      u32(len(skin.matrices)),
    )
  }
  nd.material_id = att.material.index
  nd.mesh_id = att.handle.index
  if node.visible && node.parent_visible do nd.flags |= {.VISIBLE}
  if node.culling_enabled do nd.flags |= {.CULLING_ENABLED}
  if att.cast_shadow do nd.flags |= {.CASTS_SHADOW}
  if mat, has_mat := cont.get(wld.materials, att.material); has_mat {
    nd.flags |= material_type_flags(mat.type)
  }
}

@(private = "file")
fill_sprite_node_data :: proc(
  wld: ^world.World,
  node: ^world.Node,
  att: world.SpriteAttachment,
  nd: ^render.Node,
) {
  nd.material_id = att.material.index
  nd.mesh_id = att.mesh_handle.index
  nd.attachment_data_index = att.sprite_handle.index
  if node.visible && node.parent_visible do nd.flags |= {.VISIBLE}
  if node.culling_enabled do nd.flags |= {.CULLING_ENABLED}
  nd.flags |= {.MATERIAL_SPRITE}
  if mat, has_mat := cont.get(wld.materials, att.material); has_mat {
    nd.flags |= material_type_flags(mat.type)
  }
}

@(private = "file")
INVALID_NODE :: render.Node {
  material_id           = 0xFFFFFFFF,
  mesh_id               = 0xFFFFFFFF,
  attachment_data_index = 0xFFFFFFFF,
}

@(private = "file")
sync_nodes :: proc(rndr: ^render.Manager, wld: ^world.World) {
  stale := make([dynamic]world.NodeHandle, context.temp_allocator)
  for handle, entry in wld.staging.node_data {
    node, ok := cont.get(wld.nodes, handle)
    if entry.op == .Remove || !ok {
      nd := INVALID_NODE
      render.upload_node_data(rndr, handle.index, &nd)
      append(&stale, handle)
      continue
    }
    node_data := INVALID_NODE
    node_data.world_matrix = node.transform.world_matrix
    #partial switch att in node.attachment {
    case world.MeshAttachment:
      fill_mesh_node_data(rndr, wld, node, att, handle.index, &node_data)
    case world.SpriteAttachment:
      fill_sprite_node_data(wld, node, att, &node_data)
    }
    render.upload_node_data(rndr, handle.index, &node_data)
    age_and_mark(&wld.staging.node_data, handle, entry.age, &stale)
  }
  for handle in stale {
    delete_key(&wld.staging.node_data, handle)
    render.release_bone_matrix_range_for_node(rndr, handle.index)
  }
}

// Meshes have a unique aging rule: age advances on every iteration regardless
// of op, and the stale step distinguishes Update (purge CPU geometry) from
// Remove (destroy GPU mesh slot).
@(private = "file")
sync_meshes :: proc(
  gctx: ^gpu.GPUContext,
  rndr: ^render.Manager,
  wld: ^world.World,
) {
  stale := make([dynamic]world.MeshHandle, context.temp_allocator)
  for handle, entry in wld.staging.mesh_updates {
    new_age := entry.age + 1
    wld.staging.mesh_updates[handle] = {new_age, entry.op}
    if int(new_age) >= world.FRAMES_IN_FLIGHT {
      append(&stale, handle)
      continue
    }
    if entry.op == .Update {
      if mesh := cont.get(wld.meshes, handle); mesh != nil {
        if geom, has_geom := mesh.cpu_geometry.?; has_geom {
          render.sync_mesh_geometry_for_handle(
            gctx,
            rndr,
            handle.index,
            geom,
          )
        }
      }
    }
  }
  for handle in stale {
    entry := wld.staging.mesh_updates[handle]
    if entry.op == .Remove {
      render.mesh_destroy(rndr, handle.index)
    } else if mesh := cont.get(wld.meshes, handle); mesh != nil {
      if mesh.auto_purge_cpu_geometry {
        world.mesh_release_memory(mesh)
      }
    }
    delete_key(&wld.staging.mesh_updates, handle)
  }
}

@(private = "file")
sync_materials :: proc(rndr: ^render.Manager, wld: ^world.World) {
  stale := make([dynamic]world.MaterialHandle, context.temp_allocator)
  for handle, entry in wld.staging.material_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&wld.staging.material_updates, handle, entry.age, &stale)
    material := cont.get(wld.materials, handle) or_continue
    render.upload_material_data(
      rndr,
      handle.index,
      &render.Material {
        albedo_index = material.albedo.index,
        metallic_roughness_index = material.metallic_roughness.index,
        normal_index = material.normal.index,
        emissive_index = material.emissive.index,
        features = transmute(render.ShaderFeatureSet)material.features,
        metallic_value = material.metallic_value,
        roughness_value = material.roughness_value,
        emissive_value = material.emissive_value,
        base_color_factor = material.base_color_factor,
      },
    )
  }
  for handle in stale do delete_key(&wld.staging.material_updates, handle)
}

@(private = "file")
sync_bones :: proc(
  rndr: ^render.Manager,
  wld: ^world.World,
  frame_index: u32,
) {
  stale := make([dynamic]world.NodeHandle, context.temp_allocator)
  for handle, entry in wld.staging.bone_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&wld.staging.bone_updates, handle, entry.age, &stale)
    node := cont.get(wld.nodes, handle) or_continue
    mesh_attachment, has_mesh := node.attachment.(world.MeshAttachment)
    if !has_mesh do continue
    skinning, has_skinning := mesh_attachment.skinning.?
    if !has_skinning do continue
    bone_count := u32(len(skinning.matrices))
    if bone_count <= 0 do continue
    offset := render.ensure_bone_matrix_range_for_node(
      rndr,
      handle.index,
      bone_count,
    )
    if offset != 0xFFFFFFFF {
      render.upload_bone_matrices(
        rndr,
        frame_index,
        offset,
        skinning.matrices[:],
      )
    }
  }
  for handle in stale do delete_key(&wld.staging.bone_updates, handle)
}

@(private = "file")
sync_sprites :: proc(rndr: ^render.Manager, wld: ^world.World) {
  stale := make([dynamic]world.SpriteHandle, context.temp_allocator)
  for handle, entry in wld.staging.sprite_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&wld.staging.sprite_updates, handle, entry.age, &stale)
    sprite := cont.get(wld.sprites, handle) or_continue
    sprite_anim, has_anim := sprite.animation.?
    render.upload_sprite_data(
      rndr,
      handle.index,
      &render.Sprite {
        texture_index = sprite.texture.index,
        frame_columns = sprite.frame_columns,
        frame_rows = sprite.frame_rows,
        frame_index = sprite_anim.current_frame if has_anim else 0,
      },
    )
  }
  for handle in stale do delete_key(&wld.staging.sprite_updates, handle)
}

@(private = "file")
sync_emitters :: proc(rndr: ^render.Manager, wld: ^world.World) {
  stale := make([dynamic]world.EmitterHandle, context.temp_allocator)
  for handle, entry in wld.staging.emitter_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&wld.staging.emitter_updates, handle, entry.age, &stale)
    emitter := cont.get(wld.emitters, handle) or_continue
    render.upload_emitter_data(
      rndr,
      handle.index,
      &render.Emitter {
        initial_velocity = emitter.initial_velocity,
        size_start = emitter.size_start,
        color_start = emitter.color_start,
        color_end = emitter.color_end,
        aabb_min = emitter.aabb_min,
        emission_rate = emitter.emission_rate,
        aabb_max = emitter.aabb_max,
        particle_lifetime = emitter.particle_lifetime,
        position_spread = emitter.position_spread,
        velocity_spread = emitter.velocity_spread,
        emit_count = emitter.pending_emit,
        size_end = emitter.size_end,
        weight = emitter.weight,
        weight_spread = emitter.weight_spread,
        texture_index = emitter.texture_handle.index,
        node_index = emitter.node_handle.index,
      },
    )
  }
  for handle in stale do delete_key(&wld.staging.emitter_updates, handle)
}

@(private = "file")
sync_forcefields :: proc(rndr: ^render.Manager, wld: ^world.World) {
  stale := make([dynamic]world.ForceFieldHandle, context.temp_allocator)
  for handle, entry in wld.staging.forcefield_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&wld.staging.forcefield_updates, handle, entry.age, &stale)
    forcefield := cont.get(wld.forcefields, handle) or_continue
    gpu_strength := forcefield.strength if forcefield.enabled else 0
    gpu_tangent := forcefield.tangent_strength if forcefield.enabled else 0
    render.upload_forcefield_data(
      rndr,
      handle.index,
      &render.ForceField {
        tangent_strength = gpu_tangent,
        strength = gpu_strength,
        area_of_effect = forcefield.area_of_effect,
        node_index = forcefield.node_handle.index,
      },
    )
  }
  for handle in stale do delete_key(&wld.staging.forcefield_updates, handle)
}

@(private = "file")
render_light_from_view :: proc(lv: world.LightView) -> render.Light {
  switch lv.kind {
  case .POINT:
    return render.Light(render.PointLight{
      color    = lv.color,
      position = lv.position,
      radius   = lv.radius,
    })
  case .DIRECTIONAL:
    return render.Light(render.DirectionalLight{
      color     = lv.color,
      position  = lv.position,
      direction = lv.direction,
      radius    = lv.radius,
    })
  case .SPOT:
    return render.Light(render.SpotLight{
      color       = lv.color,
      position    = lv.position,
      direction   = lv.direction,
      radius      = lv.radius,
      angle_inner = lv.angle_inner,
      angle_outer = lv.angle_outer,
    })
  }
  return render.Light{}
}

@(private = "file")
sync_lights :: proc(
  gctx: ^gpu.GPUContext,
  rndr: ^render.Manager,
  wld: ^world.World,
) -> vk.Result {
  stale := make([dynamic]world.NodeHandle, context.temp_allocator)
  for node_handle, entry in wld.staging.light_updates {
    if entry.op == .Remove {
      render.remove_light_entry(rndr, gctx, node_handle.index)
      append(&stale, node_handle)
      continue
    }
    defer age_and_mark(&wld.staging.light_updates, node_handle, entry.age, &stale)
    node, ok := cont.get(wld.nodes, node_handle)
    if !ok {
      render.remove_light_entry(rndr, gctx, node_handle.index)
      continue
    }
    lv, has_view := world.light_view(node)
    if !has_view || !lv.enabled {
      render.remove_light_entry(rndr, gctx, node_handle.index)
      continue
    }
    light_data := render_light_from_view(lv)
    render.upsert_light_entry(
      rndr,
      gctx,
      node_handle.index,
      &light_data,
      lv.cast_shadow,
    ) or_return
  }
  for handle in stale do delete_key(&wld.staging.light_updates, handle)
  return .SUCCESS
}

// Camera render-side state is eagerly allocated at spawn time (engine.setup
// for the main camera, engine_helpers.create_camera for user cameras), so
// sync only forwards transform data — no lazy GPU init here.
@(private = "file")
sync_cameras :: proc(
  rndr: ^render.Manager,
  wld: ^world.World,
  frame_index: u32,
) {
  stale := make([dynamic]world.CameraHandle, context.temp_allocator)
  for handle, entry in wld.staging.camera_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&wld.staging.camera_updates, handle, entry.age, &stale)
    world_camera := cont.get(wld.cameras, handle) or_continue
    if handle.index not_in rndr.cameras do continue
    view_matrix := world.camera_view_matrix(world_camera)
    projection_matrix := world.camera_projection_matrix(world_camera)
    near, far := world.camera_get_near_far(world_camera)
    render.upload_camera_data(
      rndr,
      handle.index,
      view_matrix,
      projection_matrix,
      world_camera.position,
      world_camera.extent,
      near,
      far,
      frame_index,
    )
  }
  for handle in stale do delete_key(&wld.staging.camera_updates, handle)
}

// Drain world staging lists into render-side GPU resources. Holds the staging
// mutex for the duration so a concurrent producer can't tear an entry.
staging_to_gpu :: proc(
  gctx: ^gpu.GPUContext,
  rndr: ^render.Manager,
  wld: ^world.World,
  frame_index: u32,
) -> vk.Result {
  sync.mutex_lock(&wld.staging.mutex)
  defer sync.mutex_unlock(&wld.staging.mutex)
  sync_nodes(rndr, wld)
  sync_meshes(gctx, rndr, wld)
  sync_materials(rndr, wld)
  sync_bones(rndr, wld, frame_index)
  sync_sprites(rndr, wld)
  sync_emitters(rndr, wld)
  sync_forcefields(rndr, wld)
  sync_lights(gctx, rndr, wld) or_return
  sync_cameras(rndr, wld, frame_index)
  return .SUCCESS
}

// Drive logical UI layout + command generation, then hand the staging buffer
// to the render-side UI subrenderer.
ui_to_renderer :: proc(
  gctx: ^gpu.GPUContext,
  rndr: ^render.Manager,
  uis: ^ui_module.System,
) {
  ui_module.update_font_atlas(uis, gctx, &rndr.texture_manager)
  ui_module.compute_layout_all(uis)
  ui_module.generate_render_commands(uis)
  ui_render.stage_commands(&rndr.internal.ui, uis.staging[:])
}
