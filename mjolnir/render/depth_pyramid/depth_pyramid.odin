package depth_pyramid

import "../../gpu"
import cam "../camera"
import vk "vendor:vulkan"

SHADER_DEPTH_REDUCE :: #load("../../shader/occlusion_culling/depth_reduce.spv")

DepthReducePushConstants :: struct {
  current_mip: u32,
}

System :: struct {
  depth_reduce_layout:            vk.PipelineLayout,
  depth_reduce_pipeline:          vk.Pipeline,
  depth_reduce_descriptor_layout: vk.DescriptorSetLayout,
  node_count:                     u32,
}

init :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  self.depth_reduce_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}},
    {.STORAGE_IMAGE, {.COMPUTE}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.depth_reduce_descriptor_layout,
      nil,
    )
    self.depth_reduce_descriptor_layout = 0
  }
  self.depth_reduce_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(DepthReducePushConstants),
    },
    self.depth_reduce_descriptor_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.depth_reduce_layout, nil)
    self.depth_reduce_layout = 0
  }
  depth_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_DEPTH_REDUCE,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, depth_shader, nil)
  self.depth_reduce_pipeline = gpu.create_compute_pipeline(
    gctx,
    depth_shader,
    self.depth_reduce_layout,
  ) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^System, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.depth_reduce_pipeline, nil)
  self.depth_reduce_pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.depth_reduce_layout, nil)
  self.depth_reduce_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.depth_reduce_descriptor_layout,
    nil,
  )
  self.depth_reduce_descriptor_layout = 0
}

build_pyramid :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  camera: ^cam.Camera,
  frame_index: u32,
) {
  if self.node_count == 0 do return
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.depth_reduce_pipeline)
  for mip in 0 ..< camera.depth_pyramid[frame_index].mip_levels {
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      self.depth_reduce_layout,
      0,
      1,
      &camera.depth_reduce_descriptor_sets[frame_index][mip],
      0,
      nil,
    )
    push_constants := DepthReducePushConstants {
      current_mip = u32(mip),
    }
    vk.CmdPushConstants(
      command_buffer,
      self.depth_reduce_layout,
      {.COMPUTE},
      0,
      size_of(push_constants),
      &push_constants,
    )
    mip_width := max(1, camera.depth_pyramid[frame_index].width >> mip)
    mip_height := max(1, camera.depth_pyramid[frame_index].height >> mip)
    dispatch_x := (mip_width + 31) / 32
    dispatch_y := (mip_height + 31) / 32
    vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)
    if mip < camera.depth_pyramid[frame_index].mip_levels - 1 {
      gpu.memory_barrier(
        command_buffer,
        {.SHADER_WRITE},
        {.SHADER_READ},
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
      )
    }
  }
}
