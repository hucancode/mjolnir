#+private
package render

import "gpu"
import vk "vendor:vulkan"

LIGHTING_SHADER_VERT :: #load("shader/lighting/vert.spv")
LIGHTING_SHADER_FRAG :: #load("shader/lighting/frag.spv")
AMBIENT_SHADER_FRAG :: #load("shader/lighting_ambient/frag.spv")

// Pushed once per camera, read by every lighting pipeline. The camera's view
// holds its G-buffer.
LightingPushConstants :: struct {
  camera_index:     u32,
  irradiance:       u32,
  prefilter:        u32,
  brdf_lut:         u32,
  environment:      u32,
  skybox_intensity: f32,
  skybox_blur:      f32,
}

// The volume each light type rasterizes, one instance per light, and the
// fragment shader shading it. Point and spot draw their builtin volume mesh's
// back faces where the scene lies in front of them; directional and ambient
// lights (no volume) cover the screen with the vertex shader's clip-space
// triangle on the far plane, directional only where the scene lies in front
// of it.
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

// Record one camera's lighting: every light as one instance of its type's
// volume, additively over the cleared color image and depth-tested against
// the G-buffer depth. record_camera_passes orders it with the other passes.
lighting_record :: proc(r: ^Renderer, frame_index: u32, cam_index: u32, cam: ^Camera) {
  cmd := r.command_buffers[frame_index]
  final_image := texture_image(r, cam.attachments[.FINAL_IMAGE][frame_index])
  depth_texture := texture_image(r, cam.attachments[.DEPTH][frame_index])
  gpu.begin_rendering(
    cmd,
    depth_texture.extent,
    // read-only: light volumes depth-test against it and the shaders
    // sample it to rebuild positions
    gpu.create_depth_attachment(depth_texture.view, .LOAD, .NONE),
    gpu.create_color_attachment(final_image.view),
  )
  bind_mesh_buffers(r, cmd)
  ambient := &r.ambient
  push := LightingPushConstants {
    camera_index     = cam_index,
    irradiance       = u32(ambient.irradiance_cube),
    prefilter        = u32(ambient.prefilter_cube),
    brdf_lut         = u32(ambient.brdf_lut),
    environment      = u32(ambient.environment_map),
    skybox_intensity = ambient.skybox_intensity,
    skybox_blur      = ambient.skybox_blur,
  }
  push_constants(r, cmd, &push)
  first: u32
  for type in LightType {
    count := r.light_count[type]
    defer first += count
    if count == 0 do continue
    vk.CmdBindPipeline(cmd, .GRAPHICS, r.light_pipelines[type])
    if primitive, ok := DRAW_STATE[type].volume.?; ok {
      volume := &r.meshes[r.builtin_meshes[primitive]]
      vk.CmdDrawIndexed(cmd, volume.index_count, count, volume.first_index, volume.vertex_offset, first)
    } else {
      vk.CmdDraw(cmd, 3, count, 0, first)
    }
  }
  vk.CmdEndRendering(cmd)
}
