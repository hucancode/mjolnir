package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:time"
import "geometry"
import vk "vendor:vulkan"

compute_particles :: proc(
  renderer: ^Renderer,
  command_buffer: vk.CommandBuffer,
) {
  log.info("binding compute pipeline", renderer.pipeline_particle_comp.pipeline)
  vk.CmdBindPipeline(
    command_buffer,
    .COMPUTE,
    renderer.pipeline_particle_comp.pipeline,
  )
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    renderer.pipeline_particle_comp.pipeline_layout,
    0,
    1,
    &renderer.pipeline_particle_comp.descriptor_set,
    0,
    nil,
  )
  vk.CmdDispatch(
    command_buffer,
    u32(MAX_PARTICLES + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH,
    1,
    1,
  )
  // Insert memory barrier to ensure compute results are visible
  barrier := vk.MemoryBarrier {
    sType         = .MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.VERTEX_INPUT},
    {},
    1,
    &barrier,
    0,
    nil,
    0,
    nil,
  )
}

render_particles :: proc(engine: ^Engine, command_buffer: vk.CommandBuffer) {
  log.info(
    "binding particle render pipeline",
    engine.renderer.pipeline_particle.pipeline,
  )
  vk.CmdBindPipeline(
    command_buffer,
    .GRAPHICS,
    engine.renderer.pipeline_particle.pipeline,
  )
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    engine.renderer.pipeline_particle.pipeline_layout,
    0,
    1,
    &engine.renderer.pipeline_particle.descriptor_set,
    0,
    nil,
  )

  // Push view projection matrix for particles
  uniform := SceneUniform {
    view       = geometry.calculate_view_matrix(&engine.scene.camera),
    projection = geometry.calculate_projection_matrix(&engine.scene.camera),
  }
  vk.CmdPushConstants(
    command_buffer,
    engine.renderer.pipeline_particle.pipeline_layout,
    {.VERTEX},
    0,
    size_of(SceneUniform),
    &uniform,
  )

  // Bind particle vertex buffer and draw
  offset: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &engine.renderer.pipeline_particle_comp.particle_buffer.buffer,
    &offset,
  )
  params := data_buffer_get(engine.renderer.pipeline_particle_comp.params_buffer)
  if params.particle_count > 0 {
    vk.CmdDraw(command_buffer, u32(params.particle_count), 1, 0, 0)
  }
}
