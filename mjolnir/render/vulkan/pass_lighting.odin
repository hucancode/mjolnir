package vulkan_backend

import vk "vendor:vulkan"

// LightType selects the light branch of the lighting shaders.
// AMBIENT is the environment light (image-based lighting, emissive, skybox), one per frame.
LightType :: enum u16 {
  POINT,
  SPOT,
  DIRECTIONAL,
  AMBIENT,
}

@(private = "file")
LIGHTING_SHADER_VERT :: #load("shader/lighting/vert.spv")
@(private = "file")
LIGHTING_SHADER_FRAG :: #load("shader/lighting/frag.spv")
@(private = "file")
AMBIENT_SHADER_FRAG :: #load("shader/lighting_ambient/frag.spv")

@(private = "file")
LightingPushConstants :: struct {
  camera_index:     u32,
  irradiance:       u32,
  prefilter:        u32,
  brdf_lut:         u32,
  environment:      u32,
  skybox_intensity: f32,
  skybox_blur:      f32,
}

// Point and spot draw the back faces of their volume mesh (FrameDesc.light_volumes);
// directional and ambient cover the screen with a far-plane triangle, directional only where
// the scene lies in front of it.
@(private = "file")
DRAW_STATE := [LightType]struct {
  depth_compare: vk.CompareOp,
  cull:          vk.CullModeFlags,
  frag:          []u8,
} {
  .POINT       = {.GREATER_OR_EQUAL, {.FRONT}, LIGHTING_SHADER_FRAG},
  .SPOT        = {.GREATER_OR_EQUAL, {.BACK}, LIGHTING_SHADER_FRAG},
  .DIRECTIONAL = {.GREATER, {.BACK}, LIGHTING_SHADER_FRAG},
  .AMBIENT     = {.ALWAYS, {.BACK}, AMBIENT_SHADER_FRAG},
}

@(private)
direct_light_init :: proc(b: ^Backend) -> vk.Result {
  gctx := &b.gctx
  light_type_entry := vk.SpecializationMapEntry{constantID = 0, size = size_of(u32)}
  color_formats := [?]vk.Format{FORMATS[HDR_COLOR_FORMAT]}
  blend := [?]vk.PipelineColorBlendAttachmentState{BLEND_ADDITIVE}
  for type in LightType {
    light_type := u32(type)
    specialization := vk.SpecializationInfo {
      mapEntryCount = 1,
      pMapEntries   = &light_type_entry,
      dataSize      = size_of(light_type),
      pData         = &light_type,
    }
    depth := READ_ONLY_DEPTH_STATE
    depth.depthCompareOp = DRAW_STATE[type].depth_compare
    b.light_pipelines[type] = create_graphics_pipeline(
      gctx,
      {
        vert = LIGHTING_SHADER_VERT,
        frag = DRAW_STATE[type].frag,
        specialization = &specialization,
        vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:1],
        topology = .TRIANGLE_LIST,
        cull_mode = DRAW_STATE[type].cull,
        depth = depth,
        blend = blend[:],
        color_formats = color_formats[:],
        depth_format = FORMATS[ATTACHMENTS[.DEPTH].format],
        layout = b.scene.layout,
      },
    ) or_return
  }
  return .SUCCESS
}

@(private)
lighting_record :: proc(b: ^Backend, desc: ^FrameDesc, frame_index: u32, cam: ^FrameCamera) {
  cmd := b.command_buffers[frame_index]
  final_image := texture_image(b, cam.attachments[.FINAL_IMAGE])
  depth_texture := texture_image(b, cam.attachments[.DEPTH])
  begin_rendering(
    cmd,
    depth_texture.extent,
    // read-only: volumes depth-test against it and shaders sample it
    create_depth_attachment(depth_texture.view, .LOAD, .NONE),
    create_color_attachment(final_image.view),
  )
  bind_mesh_buffers(b, cmd)
  push := LightingPushConstants {
    camera_index     = cam.index,
    irradiance       = u32(desc.irradiance_cube),
    prefilter        = u32(desc.prefilter_cube),
    brdf_lut         = u32(desc.brdf_lut),
    environment      = u32(desc.environment_map),
    skybox_intensity = desc.skybox_intensity,
    skybox_blur      = desc.skybox_blur,
  }
  push_constants(b, cmd, &push)
  first: u32
  for type in LightType {
    count := desc.light_count[type]
    defer first += count
    if count == 0 do continue
    vk.CmdBindPipeline(cmd, .GRAPHICS, b.light_pipelines[type])
    if volume := &desc.light_volumes[type]; volume.index_count > 0 {
      vk.CmdDrawIndexed(cmd, volume.index_count, count, volume.first_index, volume.vertex_offset, first)
    } else {
      vk.CmdDraw(cmd, 3, count, 0, first)
    }
  }
  vk.CmdEndRendering(cmd)
}
