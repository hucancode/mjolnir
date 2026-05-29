package mjolnir

import cont "containers"
import "core:math/linalg"
import "core:sync"
import "render"
import ui_render "render/ui"
import ui_module "ui"
import vk "vendor:vulkan"
import "world"

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
sync_nodes :: proc(self: ^Engine) {
  stale := make([dynamic]world.NodeHandle, context.temp_allocator)
  for handle, entry in self.world.staging.node_data {
    if entry.op == .Remove {
      node_data := render.Node {
        material_id           = 0xFFFFFFFF,
        mesh_id               = 0xFFFFFFFF,
        attachment_data_index = 0xFFFFFFFF,
      }
      render.upload_node_data(&self.render, handle.index, &node_data)
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&self.world.staging.node_data, handle, entry.age, &stale)
    node_data := render.Node {
      material_id           = 0xFFFFFFFF,
      mesh_id               = 0xFFFFFFFF,
      attachment_data_index = 0xFFFFFFFF,
    }
    defer render.upload_node_data(&self.render, handle.index, &node_data)
    node := cont.get(self.world.nodes, handle) or_continue
    node_data.world_matrix = node.transform.world_matrix
    // When a staged node is not found (nil), it means the node was despawned.
    // Trigger cleanup in Render module by releasing GPU resources.
    // This eliminates the need for a separate pending removal list in World module.
    #partial switch attachment in node.attachment {
    case world.MeshAttachment:
      if skinning, has_skin := attachment.skinning.?; has_skin {
        node_data.attachment_data_index =
          render.ensure_bone_matrix_range_for_node(
            &self.render,
            handle.index,
            u32(len(skinning.matrices)),
          )
      }
      node_data.material_id = attachment.material.index
      node_data.mesh_id = attachment.handle.index
      if node.visible && node.parent_visible do node_data.flags |= {.VISIBLE}
      if node.culling_enabled do node_data.flags |= {.CULLING_ENABLED}
      if attachment.cast_shadow do node_data.flags |= {.CASTS_SHADOW}
      if material, has_mat := cont.get(
        self.world.materials,
        attachment.material,
      ); has_mat {
        switch material.type {
        case .TRANSPARENT:
          node_data.flags |= {.MATERIAL_TRANSPARENT}
        case .WIREFRAME:
          node_data.flags |= {.MATERIAL_WIREFRAME}
        case .RANDOM_COLOR:
          node_data.flags |= {.MATERIAL_RANDOM_COLOR}
        case .LINE_STRIP:
          node_data.flags |= {.MATERIAL_LINE_STRIP}
        case .PBR, .UNLIT:
        }
      }
    case world.SpriteAttachment:
      node_data.material_id = attachment.material.index
      node_data.mesh_id = attachment.mesh_handle.index
      node_data.attachment_data_index = attachment.sprite_handle.index
      if node.visible && node.parent_visible do node_data.flags |= {.VISIBLE}
      if node.culling_enabled do node_data.flags |= {.CULLING_ENABLED}
      node_data.flags |= {.MATERIAL_SPRITE}
      if material, has_mat := cont.get(
        self.world.materials,
        attachment.material,
      ); has_mat {
        switch material.type {
        case .TRANSPARENT:
          node_data.flags |= {.MATERIAL_TRANSPARENT}
        case .WIREFRAME:
          node_data.flags |= {.MATERIAL_WIREFRAME}
        case .RANDOM_COLOR:
          node_data.flags |= {.MATERIAL_RANDOM_COLOR}
        case .LINE_STRIP:
          node_data.flags |= {.MATERIAL_LINE_STRIP}
        case .PBR, .UNLIT:
        }
      }
    }
  }
  for handle in stale {
    delete_key(&self.world.staging.node_data, handle)
    render.release_bone_matrix_range_for_node(&self.render, handle.index)
  }
}

// Meshes have a unique aging rule: age advances on every iteration regardless
// of op, and the stale step distinguishes Update (purge CPU geometry) from
// Remove (destroy GPU mesh slot).
@(private = "file")
sync_meshes :: proc(self: ^Engine) {
  stale := make([dynamic]world.MeshHandle, context.temp_allocator)
  for handle, entry in self.world.staging.mesh_updates {
    new_age := entry.age + 1
    self.world.staging.mesh_updates[handle] = {new_age, entry.op}
    if int(new_age) >= world.FRAMES_IN_FLIGHT {
      append(&stale, handle)
      continue
    }
    if entry.op == .Update {
      if mesh := cont.get(self.world.meshes, handle); mesh != nil {
        if geom, has_geom := mesh.cpu_geometry.?; has_geom {
          render.sync_mesh_geometry_for_handle(
            &self.gctx,
            &self.render,
            handle.index,
            geom,
          )
        }
      }
    }
  }
  for handle in stale {
    entry := self.world.staging.mesh_updates[handle]
    if entry.op == .Remove {
      render.mesh_destroy(&self.render, handle.index)
    } else if mesh := cont.get(self.world.meshes, handle); mesh != nil {
      if mesh.auto_purge_cpu_geometry {
        world.mesh_release_memory(mesh)
      }
    }
    delete_key(&self.world.staging.mesh_updates, handle)
  }
}

@(private = "file")
sync_materials :: proc(self: ^Engine) {
  stale := make([dynamic]world.MaterialHandle, context.temp_allocator)
  for handle, entry in self.world.staging.material_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&self.world.staging.material_updates, handle, entry.age, &stale)
    material := cont.get(self.world.materials, handle) or_continue
    render.upload_material_data(
      &self.render,
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
  for handle in stale do delete_key(&self.world.staging.material_updates, handle)
}

@(private = "file")
sync_bones :: proc(self: ^Engine) {
  stale := make([dynamic]world.NodeHandle, context.temp_allocator)
  for handle, entry in self.world.staging.bone_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&self.world.staging.bone_updates, handle, entry.age, &stale)
    node := cont.get(self.world.nodes, handle) or_continue
    mesh_attachment, has_mesh := node.attachment.(world.MeshAttachment)
    if !has_mesh do continue
    skinning, has_skinning := mesh_attachment.skinning.?
    if !has_skinning do continue
    bone_count := u32(len(skinning.matrices))
    if bone_count <= 0 do continue
    offset := render.ensure_bone_matrix_range_for_node(
      &self.render,
      handle.index,
      bone_count,
    )
    if offset != 0xFFFFFFFF {
      render.upload_bone_matrices(
        &self.render,
        self.frame_index,
        offset,
        skinning.matrices[:],
      )
    }
  }
  for handle in stale do delete_key(&self.world.staging.bone_updates, handle)
}

@(private = "file")
sync_sprites :: proc(self: ^Engine) {
  stale := make([dynamic]world.SpriteHandle, context.temp_allocator)
  for handle, entry in self.world.staging.sprite_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&self.world.staging.sprite_updates, handle, entry.age, &stale)
    sprite := cont.get(self.world.sprites, handle) or_continue
    sprite_anim, has_anim := sprite.animation.?
    render.upload_sprite_data(
      &self.render,
      handle.index,
      &render.Sprite {
        texture_index = sprite.texture.index,
        frame_columns = sprite.frame_columns,
        frame_rows = sprite.frame_rows,
        frame_index = sprite_anim.current_frame if has_anim else 0,
      },
    )
  }
  for handle in stale do delete_key(&self.world.staging.sprite_updates, handle)
}

@(private = "file")
sync_emitters :: proc(self: ^Engine) {
  stale := make([dynamic]world.EmitterHandle, context.temp_allocator)
  for handle, entry in self.world.staging.emitter_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&self.world.staging.emitter_updates, handle, entry.age, &stale)
    emitter := cont.get(self.world.emitters, handle) or_continue
    render.upload_emitter_data(
      &self.render,
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
  for handle in stale do delete_key(&self.world.staging.emitter_updates, handle)
}

@(private = "file")
sync_forcefields :: proc(self: ^Engine) {
  stale := make([dynamic]world.ForceFieldHandle, context.temp_allocator)
  for handle, entry in self.world.staging.forcefield_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&self.world.staging.forcefield_updates, handle, entry.age, &stale)
    forcefield := cont.get(self.world.forcefields, handle) or_continue
    gpu_strength := forcefield.strength if forcefield.enabled else 0
    gpu_tangent := forcefield.tangent_strength if forcefield.enabled else 0
    render.upload_forcefield_data(
      &self.render,
      handle.index,
      &render.ForceField {
        tangent_strength = gpu_tangent,
        strength = gpu_strength,
        area_of_effect = forcefield.area_of_effect,
        node_index = forcefield.node_handle.index,
      },
    )
  }
  for handle in stale do delete_key(&self.world.staging.forcefield_updates, handle)
}

@(private = "file")
sync_lights :: proc(self: ^Engine) -> vk.Result {
  stale := make([dynamic]world.NodeHandle, context.temp_allocator)
  for node_handle, entry in self.world.staging.light_updates {
    if entry.op == .Remove {
      render.remove_light_entry(&self.render, &self.gctx, node_handle.index)
      append(&stale, node_handle)
      continue
    }
    defer age_and_mark(&self.world.staging.light_updates, node_handle, entry.age, &stale)
    node, ok := cont.get(self.world.nodes, node_handle)
    if !ok {
      render.remove_light_entry(&self.render, &self.gctx, node_handle.index)
      continue
    }
    light_position := node.transform.world_matrix[3].xyz
    light_direction := node.transform.world_matrix[2].xyz
    if linalg.dot(light_direction, light_direction) < 1e-6 {
      light_direction = {0, -1, 0}
    } else {
      light_direction = linalg.normalize(light_direction)
    }
    light_data: render.Light
    has_light := true
    #partial switch attachment in node.attachment {
    case world.PointLightAttachment:
      if attachment.disabled {
        has_light = false
        break
      }
      light_variant := render.PointLight {
        color    = attachment.color,
        position = light_position,
        radius   = attachment.radius,
      }
      light_data = render.Light(light_variant)
    case world.DirectionalLightAttachment:
      if attachment.disabled {
        has_light = false
        break
      }
      light_variant := render.DirectionalLight {
        color     = attachment.color,
        position  = light_position,
        direction = light_direction,
        radius    = attachment.radius,
      }
      light_data = render.Light(light_variant)
    case world.SpotLightAttachment:
      if attachment.disabled {
        has_light = false
        break
      }
      light_variant := render.SpotLight {
        color       = attachment.color,
        position    = light_position,
        direction   = light_direction,
        radius      = attachment.radius,
        angle_inner = attachment.angle_inner,
        angle_outer = attachment.angle_outer,
      }
      light_data = render.Light(light_variant)
    case:
      has_light = false
    }
    if has_light {
      cast_shadow := false
      #partial switch att in node.attachment {
      case world.PointLightAttachment:
        cast_shadow = att.cast_shadow
      case world.DirectionalLightAttachment:
        cast_shadow = att.cast_shadow
      case world.SpotLightAttachment:
        cast_shadow = att.cast_shadow
      }
      render.upsert_light_entry(
        &self.render,
        &self.gctx,
        node_handle.index,
        &light_data,
        cast_shadow,
      ) or_return
    } else {
      render.remove_light_entry(&self.render, &self.gctx, node_handle.index)
    }
  }
  for handle in stale do delete_key(&self.world.staging.light_updates, handle)
  return .SUCCESS
}

// Cameras have an extra step: first-time-seen camera handles trigger render
// GPU-side init + descriptor allocation before the standard data upload.
@(private = "file")
sync_cameras :: proc(self: ^Engine) -> vk.Result {
  stale := make([dynamic]world.CameraHandle, context.temp_allocator)
  for handle, entry in self.world.staging.camera_updates {
    if entry.op == .Remove {
      append(&stale, handle)
      continue
    }
    defer age_and_mark(&self.world.staging.camera_updates, handle, entry.age, &stale)
    world_camera := cont.get(self.world.cameras, handle) or_continue
    is_new_camera := handle.index not_in self.render.cameras
    if is_new_camera {
      self.render.cameras[handle.index] = {}
    }
    cam := &self.render.cameras[handle.index]
    view_matrix := world.camera_view_matrix(world_camera)
    projection_matrix := world.camera_projection_matrix(world_camera)
    near, far := world.camera_get_near_far(world_camera)
    render.upload_camera_data(
      &self.render,
      handle.index,
      view_matrix,
      projection_matrix,
      world_camera.position,
      world_camera.extent,
      near,
      far,
      self.frame_index,
    )
    if is_new_camera {
      render.camera_init(
        &self.gctx,
        cam,
        &self.render.texture_manager,
        vk.Extent2D{world_camera.extent[0], world_camera.extent[1]},
        self.swapchain.format.format,
        vk.Format.D32_SFLOAT,
        render.DEFAULT_ENABLED_PASSES,
        true,
        render.MAX_NODES_IN_SCENE,
      ) or_return
      render.camera_allocate_descriptors(&self.render, &self.gctx, cam) or_return
    }
  }
  for handle in stale do delete_key(&self.world.staging.camera_updates, handle)
  return .SUCCESS
}

sync_staging_to_gpu :: proc(self: ^Engine) -> vk.Result {
  sync.mutex_lock(&self.world.staging.mutex)
  defer sync.mutex_unlock(&self.world.staging.mutex)
  sync_nodes(self)
  sync_meshes(self)
  sync_materials(self)
  sync_bones(self)
  sync_sprites(self)
  sync_emitters(self)
  sync_forcefields(self)
  sync_lights(self) or_return
  sync_cameras(self) or_return
  when DEBUG_SHOW_BONES {
    debug_skeletons(self)
  }
  return .SUCCESS
}

// Sync UI render commands to the renderer (staging list pattern)
sync_ui_to_renderer :: proc(self: ^Engine) {
  ui_module.update_font_atlas(
    &self.ui,
    &self.gctx,
    &self.render.texture_manager,
  )
  ui_module.compute_layout_all(&self.ui)
  ui_module.generate_render_commands(&self.ui)
  ui_render.stage_commands(&self.render.internal.ui, self.ui.staging[:])
}
