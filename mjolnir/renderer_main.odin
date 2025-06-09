package mjolnir

import "core:fmt"
import "core:log"
import linalg "core:math/linalg"
import "core:time"
import "geometry"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

render_main_pass :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  camera_frustum: geometry.Frustum,
  swapchain_extent: vk.Extent2D, // New parameter for swapchain extent
) -> vk.Result {
  particles := engine.renderer.pipeline_particle_comp.particle_buffer.mapped
  // Run particle compute pass before starting rendering
  compute_particles(&engine.renderer, command_buffer)
  // Barrier to ensure compute shader writes are visible to the vertex shader
  particle_buffer_barrier := vk.BufferMemoryBarrier {
    sType               = .BUFFER_MEMORY_BARRIER,
    srcAccessMask       = {.SHADER_WRITE},
    dstAccessMask       = {.VERTEX_ATTRIBUTE_READ},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer              = engine.renderer.pipeline_particle_comp.particle_buffer.buffer,
    size                = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER}, // srcStageMask
    {.VERTEX_INPUT}, // dstStageMask
    {}, // dependencyFlags
    0,
    nil, // memoryBarrierCount, pMemoryBarriers
    1,
    &particle_buffer_barrier, // bufferMemoryBarrierCount, pBufferMemoryBarriers
    0, // imageMemoryBarrierCount, pImageMemoryBarriers
    nil,
  )

  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = renderer_get_main_pass_view(&engine.renderer),
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue{color = {float32 = BG_BLUE_GRAY}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.renderer.depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue{depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = vk.Rect2D{extent = swapchain_extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(swapchain_extent.height), // Use parameter
    width    = f32(swapchain_extent.width), // Use parameter
    height   = -f32(swapchain_extent.height), // Use parameter
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = swapchain_extent, // Use parameter
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  rendered_count: u32 = 0
  render_meshes_ctx := RenderMeshesContext {
    engine         = engine,
    command_buffer = command_buffer,
    camera_frustum = camera_frustum,
    rendered_count = &rendered_count,
  }
  if !traverse_scene(&engine.scene, &render_meshes_ctx, render_single_node) {
    log.errorf("[RENDER] Error during scene mesh rendering")
  }
  render_particles(engine, command_buffer)
  if mu.window(&engine.ui.ctx, "Inspector", {40, 40, 300, 150}, {.NO_CLOSE}) {
    mu.label(
      &engine.ui.ctx,
      fmt.tprintf(
        "Objects %d",
        len(engine.scene.nodes.entries) - len(engine.scene.nodes.free_indices),
      ),
    )
    mu.label(&engine.ui.ctx, fmt.tprintf("Rendered %d", rendered_count))
  }
  return .SUCCESS
}

render_single_node :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^RenderMeshesContext)(cb_context)
  frame := ctx.engine.renderer.frame_index
  #partial switch data in node.attachment {
  case MeshAttachment:
    mesh := resource.get(ctx.engine.renderer.meshes, data.handle)
    if mesh == nil {
      return true
    }
    material := resource.get(ctx.engine.renderer.materials, data.material)
    if material == nil {
      return true
    }
    world_aabb := geometry.aabb_transform(
      mesh.aabb,
      node.transform.world_matrix,
    )
    if !geometry.frustum_test_aabb(&ctx.camera_frustum, world_aabb) {
      return true
    }
    pipeline :=
      pipeline3d_get_pipeline(&ctx.engine.renderer.pipeline_3d, material.features) if material.is_lit else pipeline3d_get_unlit_pipeline(&ctx.engine.renderer.pipeline_3d, material.features)
    layout := pipeline3d_get_layout(&ctx.engine.renderer.pipeline_3d)
    descriptor_sets := [?]vk.DescriptorSet {
      renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
      material.texture_descriptor_set, // set 1
      material.skinning_descriptor_sets[frame], // set 2
      ctx.engine.renderer.environment_descriptor_set, // set 3
    }
    offsets := [1]u32{0}
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
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
    mesh_skinning, mesh_has_skin := &mesh.skinning.?
    node_skinning, node_has_skin := data.skinning.?
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
    ctx.rendered_count^ += 1
  }
  return true
}

// Add render-to-texture capability
render_to_texture :: proc(
  engine: ^Engine,
  color_view: vk.ImageView,
  depth_view: vk.ImageView,
  extent: vk.Extent2D,
  camera: ^geometry.Camera = nil, // Optional custom camera
) -> vk.Result {
  command_buffer := renderer_get_command_buffer(&engine.renderer)

  // Use provided camera or scene camera
  render_camera := camera if camera != nil else &engine.scene.camera

  // Calculate view/projection matrices
  scene_uniform := SceneUniform {
    view       = geometry.calculate_view_matrix(render_camera),
    projection = geometry.calculate_projection_matrix(render_camera),
    time       = f32(
      time.duration_seconds(time.since(engine.start_timestamp)),
    ),
  }

  camera_frustum := geometry.camera_make_frustum(render_camera)

  // Render to the provided texture views
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = color_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue{color = {float32 = BG_BLUE_GRAY}},
  }

  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = depth_view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue{depthStencil = {1.0, 0}},
  }

  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = vk.Rect2D{extent = extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }

  vk.CmdBeginRenderingKHR(command_buffer, &render_info)

  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(extent.height),
    width    = f32(extent.width),
    height   = -f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }

  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

  // Update uniforms with custom camera
  data_buffer_write(
    renderer_get_camera_uniform(&engine.renderer),
    &scene_uniform,
  )

  // Render scene with custom camera
  rendered_count: u32 = 0
  render_meshes_ctx := RenderMeshesContext {
    engine         = engine,
    command_buffer = command_buffer,
    camera_frustum = camera_frustum,
    rendered_count = &rendered_count,
  }

  traverse_scene(&engine.scene, &render_meshes_ctx, render_single_node)

  vk.CmdEndRenderingKHR(command_buffer)
  return .SUCCESS
}
