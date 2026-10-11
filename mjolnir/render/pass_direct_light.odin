#+private
package render

import cont "../containers"
import "gpu"
import "core:math/linalg"
import vk "vendor:vulkan"

DIRECT_LIGHT_SHADER_VERT := #load("shader/lighting/vert.spv")
DIRECT_LIGHT_SHADER_FRAG := #load("shader/lighting/frag.spv")


// Selects the light branch of the lighting shader (specialization constant 6).
LightType :: enum u32 {
  POINT,
  SPOT,
  DIRECTIONAL,
}

// One light's parameters. Point lights ignore direction and angles;
// directional lights ignore position, radius and angles.
DirectLight :: struct {
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
#assert(MAX_TEXTURES < NO_SHADOW && MAX_CUBE_TEXTURES < NO_SHADOW)

DirectLightPushConstants :: struct {
  shadow_view_projection:      matrix[4, 4]f32,
  light_color:                 [4]f32,
  position:                    [3]f32,
  angle_inner:                 f32,
  direction:                   [3]f32,
  radius:                      f32,
  angle_outer:                 f32,
  shadow_and_camera_indices:   u32, // shadow map | camera << 16
  depth_and_normal_indices:    u32, // depth | normal << 16
  albedo_and_metallic_indices: u32, // albedo | metallic_roughness << 16
}

#assert(size_of(DirectLightPushConstants) == 128)

DirectLightRenderer :: struct {
  pipelines:       [LightType]vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
}

// DirectLight volume each type rasterizes. Point and spot draw their volume's back
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

direct_light_init :: proc(
  self: ^DirectLightRenderer,
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
      size = size_of(DirectLightPushConstants),
    },
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }
  SpecData :: struct {
    using shared: SpecConstants,
    light_type:   LightType,
  }
  N :: len(SHADER_SPEC_ENTRIES)
  entries: [N + 1]vk.SpecializationMapEntry
  copy(entries[:N], SHADER_SPEC_ENTRIES[:])
  entries[N] = {
    constantID = N,
    offset     = u32(offset_of(SpecData, light_type)),
    size       = size_of(u32),
  }
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ADDITIVE}
  defer if ret != .SUCCESS {
    for p in self.pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  }
  for type in LightType {
    data := SpecData{SHADER_SPEC_DATA, type}
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
        vert = DIRECT_LIGHT_SHADER_VERT,
        frag = DIRECT_LIGHT_SHADER_FRAG,
        specialization = &specialization,
        vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = POSITION_ATTRIBUTE_DESCRIPTIONS[:],
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

direct_light_shutdown :: proc(self: ^DirectLightRenderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  for p in self.pipelines do vk.DestroyPipeline(gctx.device, p, nil)
}

// Record one camera's lighting: ambient, then one volume per light, additively
// over the same color image and depth-tested against the G-buffer depth.
lighting_record :: proc(r: ^Manager, frame_index: u32, cam_index: u32, cam: ^Camera) {
  self := &r.internal.direct_light
  cmd := r.internal.command_buffers[frame_index]
  final_image := camera_image(r, cam, .FINAL_IMAGE, frame_index)
  depth_texture := camera_image(r, cam, .DEPTH, frame_index)
  gbuffer := camera_gbuffer(cam, frame_index)
  gpu.begin_rendering(
    cmd,
    depth_texture.extent,
    // read-only: light volumes depth-test against it and the shaders
    // sample it to rebuild positions
    gpu.create_depth_attachment(depth_texture.view, .LOAD, .NONE),
    gpu.create_color_attachment(final_image.view),
  )
  // the ambient fullscreen triangle is built unflipped
  gpu.set_viewport_scissor(cmd, depth_texture.extent, flip_y = false)
  ambient_draw(r, cmd, frame_index, cam_index, gbuffer)
  gpu.set_viewport_scissor(cmd, depth_texture.extent)
  descriptor_sets := [?]vk.DescriptorSet {
    r.internal.camera_buffer.descriptor_sets[frame_index],
    r.texture_manager.descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    cmd,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  gpu.bind_vertex_index_buffers(
    cmd,
    r.mesh_manager.vertex_buffer.buffer,
    r.mesh_manager.index_buffer.buffer,
  )
  sphere := cont.get(r.meshes, r.builtin_meshes[.SPHERE])
  cone := cont.get(r.meshes, r.builtin_meshes[.CONE])
  for &fl in r.internal.frame_lights {
    shadow_map: u32 = NO_SHADOW
    shadow_view_projection: matrix[4, 4]f32
    if sm := fl.shadow_map; sm != nil {
      shadow_map = sm.textures[frame_index].index
      shadow_view_projection = fl.info.projection if sm.cube else fl.info.view_projection
    }
    direct_light_record_light(
      self,
      cmd,
      fl.type,
      fl.params,
      cone.allocations if fl.type == .SPOT else sphere.allocations,
      cam_index,
      gbuffer,
      shadow_map,
      shadow_view_projection,
    )
  }
  vk.CmdEndRendering(cmd)
}

@(private = "file")
direct_light_record_light :: proc(
  self: ^DirectLightRenderer,
  command_buffer: vk.CommandBuffer,
  type: LightType,
  light: DirectLight,
  volume: MeshAllocations,
  camera_index: u32,
  gbuffer: GBuffer,
  shadow_map: u32,
  shadow_view_projection: matrix[4, 4]f32,
) {
  pack :: proc(lo, hi: u32) -> u32 {return (lo & 0xFFFF) | (hi << 16)}
  push := DirectLightPushConstants {
    shadow_view_projection      = shadow_view_projection,
    light_color                 = light.color,
    position                    = light.position,
    angle_inner                 = light.angle_inner,
    direction                   = light.direction,
    radius                      = light.radius,
    angle_outer                 = light.angle_outer,
    shadow_and_camera_indices   = pack(shadow_map, camera_index),
    depth_and_normal_indices    = pack(gbuffer.depth, gbuffer.normal),
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
