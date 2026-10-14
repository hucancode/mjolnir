#+private
package render

import "gpu"
import vk "vendor:vulkan"

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

// Point and spot draw the back faces of a volume mesh; directional and ambient cover the
// screen with a far-plane triangle, directional only where the scene lies in front of it.
@(private = "file")
DRAW_STATE := [LightType]struct {
  depth_compare: vk.CompareOp,
  cull:          vk.CullModeFlags,
  volume:        Maybe(Primitive),
  frag:          []u8,
} {
  .POINT       = {.GREATER_OR_EQUAL, {.FRONT}, .SPHERE, LIGHTING_SHADER_FRAG},
  .SPOT        = {.GREATER_OR_EQUAL, {.BACK}, .CONE, LIGHTING_SHADER_FRAG},
  .DIRECTIONAL = {.GREATER, {.BACK}, nil, LIGHTING_SHADER_FRAG},
  .AMBIENT     = {.ALWAYS, {.BACK}, nil, AMBIENT_SHADER_FRAG},
}

direct_light_init :: proc(r: ^Renderer) -> vk.Result {
  gctx := &r.gctx
  light_type_entry := vk.SpecializationMapEntry{constantID = 0, size = size_of(u32)}
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ADDITIVE}
  for type in LightType {
    light_type := u32(type)
    specialization := vk.SpecializationInfo {
      mapEntryCount = 1,
      pMapEntries   = &light_type_entry,
      dataSize      = size_of(light_type),
      pData         = &light_type,
    }
    depth := gpu.READ_ONLY_DEPTH_STATE
    depth.depthCompareOp = DRAW_STATE[type].depth_compare
    r.light_pipelines[type] = gpu.create_graphics_pipeline(
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
        depth_format = ATTACHMENTS[.DEPTH].format,
        layout = r.scene.layout,
      },
    ) or_return
  }
  return .SUCCESS
}

lighting_record :: proc(r: ^Renderer, frame_index: u32, cam_index: u32) {
  cmd := r.command_buffers[frame_index]
  cam := &r.cameras[cam_index]
  final_image := texture_image(r, cam.attachments[.FINAL_IMAGE][frame_index])
  depth_texture := texture_image(r, cam.attachments[.DEPTH][frame_index])
  gpu.begin_rendering(
    cmd,
    depth_texture.extent,
    // read-only: volumes depth-test against it and shaders sample it
    gpu.create_depth_attachment(depth_texture.view, .LOAD, .NONE),
    gpu.create_color_attachment(final_image.view),
  )
  bind_mesh_buffers(r, cmd)
  push := LightingPushConstants {
    camera_index     = cam_index,
    irradiance       = u32(r.irradiance_cube),
    prefilter        = u32(r.prefilter_cube),
    brdf_lut         = u32(r.brdf_lut),
    environment      = u32(r.environment_map),
    skybox_intensity = r.skybox_intensity,
    skybox_blur      = r.skybox_blur,
  }
  push_constants(r, cmd, &push)
  first: u32
  for type in LightType {
    count := r.light_count[type]
    defer first += count
    if count == 0 do continue
    vk.CmdBindPipeline(cmd, .GRAPHICS, r.light_pipelines[type])
    if primitive, ok := DRAW_STATE[type].volume.?; ok {
      volume := &write_table(r, .MESHES, MeshData)[r.builtin_meshes[primitive]]
      vk.CmdDrawIndexed(cmd, volume.index_count, count, volume.first_index, volume.vertex_offset, first)
    } else {
      vk.CmdDraw(cmd, 3, count, 0, first)
    }
  }
  vk.CmdEndRendering(cmd)
}
