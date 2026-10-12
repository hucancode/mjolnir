#+private
package render

import "gpu"
import cont "../containers"
import vk "vendor:vulkan"

LIGHTING_SHADER_VERT :: #load("shader/lighting/vert.spv")
LIGHTING_SHADER_FRAG :: #load("shader/lighting/frag.spv")
AMBIENT_SHADER_FRAG :: #load("shader/lighting_ambient/frag.spv")

// Selects the light branch of the lighting shaders (specialization constant 0).
// AMBIENT is the environment light: image-based lighting, emissive and the
// skybox, one per frame.
LightType :: enum u32 {
  POINT,
  SPOT,
  DIRECTIONAL,
  AMBIENT,
}

// One light as the lighting shaders read it from the light buffer. Point
// lights ignore direction and angles; directional lights shade with neither
// position, radius nor angles, which place and size their shadow map.
LightGPU :: struct {
  color:       [4]f32, // RGB + intensity
  position:    [3]f32,
  radius:      f32,
  direction:   [3]f32, // normalized
  angle_inner: f32,
  angle_outer: f32,
  // view table index of the shadow map's first face, NO_SHADOW without one
  shadow_map:  u32,
  // world size of a shadow texel; per unit of view depth for point and spot
  shadow_texel: f32,
  type:        LightType,
}

// shadow_map value for a light without a shadow map.
NO_SHADOW :: 0xFFFFFFFF

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

direct_light_init :: proc(r: ^Manager) -> vk.Result {
  gctx := &r.gctx
  light_type_entry := vk.SpecializationMapEntry{constantID = 0, size = size_of(LightType)}
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ADDITIVE}
  for type in LightType {
    light_type := type
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
lighting_record :: proc(r: ^Manager, frame_index: u32, cam_index: u32, cam: ^Camera) {
  cmd := r.command_buffers[frame_index]
  final_image := camera_image(r, cam, .FINAL_IMAGE, frame_index)
  depth_texture := camera_image(r, cam, .DEPTH, frame_index)
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
    irradiance       = texture_index(ambient.irradiance_cube),
    prefilter        = texture_index(ambient.prefilter_cube),
    brdf_lut         = texture_index(ambient.brdf_lut),
    environment      = texture_index(ambient.environment_map),
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
      volume, _ := cont.get(r.meshes, r.builtin_meshes[primitive])
      vk.CmdDrawIndexed(cmd, volume.index_count, count, volume.first_index, volume.vertex_offset, first)
    } else {
      vk.CmdDraw(cmd, 3, count, 0, first)
    }
  }
  vk.CmdEndRendering(cmd)
}
