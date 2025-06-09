package mjolnir

import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

render_shadow_pass :: proc(
  engine: ^Engine,
  light_uniform: ^SceneLightUniform,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  renderer := &engine.renderer
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(renderer, i)
    shadow_map_texture := renderer_get_shadow_map(renderer, i)
    // Transition shadow map to depth attachment
    initial_barriers := [?]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.buffer.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = shadow_map_texture.buffer.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {},
      0,
      nil,
      0,
      nil,
      len(initial_barriers),
      raw_data(initial_barriers[:]),
    )
  }
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    light := &light_uniform.lights[i]
    if !light.has_shadow || i >= MAX_SHADOW_MAPS {
      continue
    }
    if light.kind == .POINT {
      cube_shadow := renderer_get_cube_shadow_map(renderer, i)
      light_pos := light.position.xyz
      // Cube face directions and up vectors
      face_dirs := [6][3]f32 {
        {1, 0, 0},
        {-1, 0, 0},
        {0, 1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
      }
      face_ups := [6][3]f32 {
        {0, -1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
        {0, -1, 0},
        {0, -1, 0},
      }
      proj := linalg.matrix4_perspective(
        math.PI * 0.5,
        1.0,
        0.01,
        light.radius,
      )
      for face in 0 ..< 6 {
        view := linalg.matrix4_look_at(
          light_pos,
          light_pos + face_dirs[face],
          face_ups[face],
        )
        face_depth_attachment := vk.RenderingAttachmentInfoKHR {
          sType = .RENDERING_ATTACHMENT_INFO_KHR,
          imageView = cube_shadow.views[face],
          imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          loadOp = .CLEAR,
          storeOp = .STORE,
          clearValue = {depthStencil = {depth = 1.0}},
        }
        face_render_info := vk.RenderingInfoKHR {
          sType = .RENDERING_INFO_KHR,
          renderArea = {
            extent = {
              width = cube_shadow.buffer.width,
              height = cube_shadow.buffer.height,
            },
          },
          layerCount = 1,
          pDepthAttachment = &face_depth_attachment,
        }
        viewport := vk.Viewport {
          width    = f32(cube_shadow.buffer.width),
          height   = f32(cube_shadow.buffer.height),
          minDepth = 0.0,
          maxDepth = 1.0,
        }
        scissor := vk.Rect2D {
          extent = {
            width = cube_shadow.buffer.width,
            height = cube_shadow.buffer.height,
          },
        }
        shadow_scene_uniform := SceneUniform {
          view       = view,
          projection = proj,
        }
        data_buffer_write(
          renderer_get_camera_uniform(renderer),
          &shadow_scene_uniform,
          i * 6 + face + 1,
        )
        vk.CmdBeginRenderingKHR(command_buffer, &face_render_info)
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
        obstacles_this_light: u32 = 0
        shadow_render_ctx := ShadowRenderContext {
          engine          = engine,
          command_buffer  = command_buffer,
          obstacles_count = &obstacles_this_light,
          shadow_idx      = u32(i),
          shadow_layer    = u32(face),
          frustum         = geometry.make_frustum(proj * view),
        }
        traverse_scene(&engine.scene, &shadow_render_ctx, render_single_shadow)
        vk.CmdEndRenderingKHR(command_buffer)
      }
    } else {
      shadow_map_texture := renderer_get_shadow_map(renderer, i)
      view: linalg.Matrix4f32
      proj: linalg.Matrix4f32
      if light.kind == .DIRECTIONAL {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_Y_AXIS,
        )
        ortho_size: f32 = 20.0
        proj = linalg.matrix_ortho3d(
          -ortho_size,
          ortho_size,
          -ortho_size,
          ortho_size,
          0.1,
          light.radius,
        )
      } else {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_X_AXIS,
          // TODO: hardcoding up vector will not work if the light is perfectly aligned with said vector
        )
        proj = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius)
      }
      light.view_proj = proj * view
      depth_attachment := vk.RenderingAttachmentInfoKHR {
        sType = .RENDERING_ATTACHMENT_INFO_KHR,
        imageView = shadow_map_texture.buffer.view,
        imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        loadOp = .CLEAR,
        storeOp = .STORE,
        clearValue = {depthStencil = {1.0, 0}},
      }
      render_info_khr := vk.RenderingInfoKHR {
        sType = .RENDERING_INFO_KHR,
        renderArea = {
          extent = {
            width = shadow_map_texture.buffer.width,
            height = shadow_map_texture.buffer.height,
          },
        },
        layerCount = 1,
        pDepthAttachment = &depth_attachment,
      }
      shadow_scene_uniform := SceneUniform {
        view       = view,
        projection = proj,
      }
      data_buffer_write(
        renderer_get_camera_uniform(renderer),
        &shadow_scene_uniform,
        i * 6 + 1,
      )
      vk.CmdBeginRenderingKHR(command_buffer, &render_info_khr)
      viewport := vk.Viewport {
        width    = f32(shadow_map_texture.buffer.width),
        height   = f32(shadow_map_texture.buffer.height),
        minDepth = 0.0,
        maxDepth = 1.0,
      }
      scissor := vk.Rect2D {
        extent = {
          width = shadow_map_texture.buffer.width,
          height = shadow_map_texture.buffer.height,
        },
      }
      vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
      vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
      obstacles_this_light: u32 = 0
      shadow_render_ctx := ShadowRenderContext {
        engine          = engine,
        command_buffer  = command_buffer,
        obstacles_count = &obstacles_this_light,
        shadow_idx      = u32(i),
        frustum         = geometry.make_frustum(proj * view),
      }
      traverse_scene(&engine.scene, &shadow_render_ctx, render_single_shadow)
      vk.CmdEndRenderingKHR(command_buffer)
    }
  }
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(renderer, i)
    shadow_map_texture := renderer_get_shadow_map(renderer, i)
    final_barriers := [?]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.buffer.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = shadow_map_texture.buffer.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.LATE_FRAGMENT_TESTS},
      {.FRAGMENT_SHADER},
      {},
      0,
      nil,
      0,
      nil,
      len(final_barriers),
      raw_data(final_barriers[:]),
    )
  }
  return .SUCCESS
}

render_single_shadow :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^ShadowRenderContext)(cb_context)
  frame := ctx.engine.renderer.frame_index
  shadow_idx := ctx.shadow_idx
  shadow_layer := ctx.shadow_layer
  #partial switch data in node.attachment {
  case MeshAttachment:
    if !data.cast_shadow {
      return true
    }
    mesh := resource.get(ctx.engine.renderer.meshes, data.handle)
    if mesh == nil {
      return true
    }
    mesh_skinning, mesh_has_skin := &mesh.skinning.?
    node_skinning, node_has_skin := data.skinning.?
    world_aabb := geometry.aabb_transform(
      mesh.aabb,
      node.transform.world_matrix,
    )
    if !geometry.frustum_test_aabb(&ctx.frustum, world_aabb) {
      return true
    }
    material := resource.get(ctx.engine.renderer.materials, data.material)
    if material == nil {
      return true
    }
    features: ShaderFeatureSet
    pipeline := pipeline_shadow_get_pipeline(
      &ctx.engine.renderer.pipeline_shadow,
      features,
    )
    layout := pipeline_shadow_get_layout(&ctx.engine.renderer.pipeline_shadow)
    descriptor_sets: []vk.DescriptorSet
    if mesh_has_skin {
      pipeline = pipeline_shadow_get_pipeline(
        &ctx.engine.renderer.pipeline_shadow,
        {.SKINNING},
      )
      descriptor_sets = {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
        material.skinning_descriptor_sets[frame], // set 1
      }
    } else {
      descriptor_sets = {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
      }
    }
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    offset_shadow := data_buffer_offset_of(
      renderer_get_camera_uniform(&ctx.engine.renderer)^,
      1 + shadow_idx * 6 + shadow_layer,
    )
    offsets := [1]u32{offset_shadow}
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      &node.transform.world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    if mesh_has_skin && node_has_skin {
      material_update_bone_buffer(
        material,
        node_skinning.bone_buffers[frame].buffer,
        vk.DeviceSize(node_skinning.bone_buffers[frame].bytes_count),
        frame,
      )
      vk.CmdBindVertexBuffers(
        ctx.command_buffer,
        1,
        1,
        &mesh_skinning.skin_buffer.buffer,
        &offset,
      )
    }
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.obstacles_count^ += 1
  }
  return true
}
