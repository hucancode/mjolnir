package direct_light

import "../bindless"
import "../gpu"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADER_VERT := #load("../shader/lighting/vert.spv")
SHADER_FRAG := #load("../shader/lighting/frag.spv")

@(private)
BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}

// Selects the light branch of the lighting shader (specialization constant 6).
LightType :: enum u32 {
  POINT,
  SPOT,
  DIRECTIONAL,
}

// One light's parameters. Point lights ignore direction and angles;
// directional lights ignore position, radius and angles.
Light :: struct {
  color:       [4]f32, // RGB + intensity
  position:    [3]f32,
  direction:   [3]f32,
  radius:      f32,
  angle_inner: f32,
  angle_outer: f32,
}

// shadow_map value for a light without a shadow map.
NO_SHADOW :: 0xFFFF

// Indices travel as 16-bit halves of a u32.
#assert(bindless.MAX_TEXTURES < NO_SHADOW && bindless.MAX_CUBE_TEXTURES < NO_SHADOW)

@(private)
PushConstants :: struct {
  shadow_view_projection:      matrix[4, 4]f32,
  light_color:                 [4]f32,
  position:                    [3]f32,
  angle_inner:                 f32,
  direction:                   [3]f32,
  radius:                      f32,
  angle_outer:                 f32,
  shadow_and_camera_indices:   u32, // shadow map | camera << 16
  position_and_normal_indices: u32, // position | normal << 16
  albedo_and_metallic_indices: u32, // albedo | metallic_roughness << 16
}

#assert(size_of(PushConstants) == 128)

Renderer :: struct {
  pipelines:       [LightType]vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
}

// Light volume each type rasterizes. Point and spot draw their volume's back
// faces where the scene lies in front of them; directional lights cover the
// whole screen.
@(private = "file")
DRAW_STATE := [LightType]struct {
  depth_compare: vk.CompareOp,
  cull:          vk.CullModeFlags,
} {
  .POINT       = {.GREATER_OR_EQUAL, {.FRONT}},
  .SPOT        = {.GREATER_OR_EQUAL, {.BACK}},
  .DIRECTIONAL = {.ALWAYS, {.BACK}},
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(PushConstants),
    },
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }
  vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  SpecData :: struct {
    using shared: bindless.Constants,
    light_type:   LightType,
  }
  N :: len(bindless.SHADER_SPEC_ENTRIES)
  entries: [N + 1]vk.SpecializationMapEntry
  copy(entries[:N], bindless.SHADER_SPEC_ENTRIES[:])
  entries[N] = {
    constantID = N,
    offset     = u32(offset_of(SpecData, light_type)),
    size       = size_of(u32),
  }
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_OVERFLOW}
  defer if ret != .SUCCESS {
    for p in self.pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  }
  for type in LightType {
    data := SpecData{bindless.SHADER_SPEC_DATA, type}
    specialization := vk.SpecializationInfo {
      mapEntryCount = len(entries),
      pMapEntries   = raw_data(entries[:]),
      dataSize      = size_of(data),
      pData         = &data,
    }
    raster := gpu.STANDARD_RASTERIZER
    raster.cullMode = DRAW_STATE[type].cull
    depth := gpu.READ_ONLY_DEPTH_STATE
    depth.depthCompareOp = DRAW_STATE[type].depth_compare
    self.pipelines[type] = gpu.create_graphics_pipeline(
      gctx,
      {
        vert = vert_module,
        frag = frag_module,
        specialization = &specialization,
        vertex_bindings = bindless.VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = bindless.POSITION_ATTRIBUTE_DESCRIPTIONS[:],
        topology = .TRIANGLE_LIST,
        raster = raster,
        depth = depth,
        blend = blend[:],
        color_formats = color_formats[:],
        depth_format = .D32_SFLOAT,
        layout = self.pipeline_layout,
      },
    ) or_return
  }
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  for p in self.pipelines do vk.DestroyPipeline(gctx.device, p, nil)
}

begin_pass :: proc(
  self: ^Renderer,
  final_image_handle: bindless.Texture2DHandle,
  depth_handle: bindless.Texture2DHandle,
  texture_manager: ^bindless.TextureManager,
  command_buffer: vk.CommandBuffer,
  cameras_descriptor_set: vk.DescriptorSet,
  vertex_buffer, index_buffer: vk.Buffer,
) {
  final_image := bindless.get_texture_2d(
    texture_manager,
    final_image_handle,
  )
  depth_texture := bindless.get_texture_2d(
    texture_manager,
    depth_handle,
  )
  gpu.begin_rendering(
    command_buffer,
    depth_texture.extent,
    gpu.create_depth_attachment(
      depth_texture.view,
      .LOAD,
      .DONT_CARE,
    ),
    gpu.create_color_attachment(final_image.view, .LOAD, .STORE, BG_BLUE_GRAY),
  )
  gpu.set_viewport_scissor(command_buffer, depth_texture.extent)
  descriptor_sets := [?]vk.DescriptorSet{cameras_descriptor_set, texture_manager.descriptor_set}
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    2,
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  gpu.bind_vertex_index_buffers(command_buffer, vertex_buffer, index_buffer, 0, 0)
}

// Add one light's contribution, rasterizing `volume` (a unit sphere for point
// lights, a unit cone for spot lights) from the buffers bound by begin_pass.
// `shadow_map` is a 2D texture index (cube texture for point lights) or
// NO_SHADOW.
record_light :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  type: LightType,
  light: Light,
  volume: bindless.MeshAllocations,
  camera_index: u32,
  gbuffer: bindless.GBuffer,
  shadow_map: u32,
  shadow_view_projection: matrix[4, 4]f32,
) {
  pack :: proc(lo, hi: u32) -> u32 {return (lo & 0xFFFF) | (hi << 16)}
  push := PushConstants {
    shadow_view_projection      = shadow_view_projection,
    light_color                 = light.color,
    position                    = light.position,
    angle_inner                 = light.angle_inner,
    direction                   = light.direction,
    radius                      = light.radius,
    angle_outer                 = light.angle_outer,
    shadow_and_camera_indices   = pack(shadow_map, camera_index),
    position_and_normal_indices = pack(gbuffer.position, gbuffer.normal),
    albedo_and_metallic_indices = pack(gbuffer.albedo, gbuffer.metallic_roughness),
  }
  if type == .SPOT do push.direction = linalg.normalize(light.direction)
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipelines[type])
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(push),
    &push,
  )
  // Directional lights cover the screen with a triangle built in the vertex
  // shader, ignoring the bound vertex buffer.
  if type == .DIRECTIONAL {
    vk.CmdDraw(command_buffer, 3, 1, 0, 0)
  } else {
    vk.CmdDrawIndexed(
      command_buffer,
      volume.indices.count,
      1,
      volume.indices.offset,
      i32(volume.vertices.offset),
      0,
    )
  }
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
