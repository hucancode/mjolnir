#+private
package render

import "gpu"
import "mesh"
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
// lights ignore direction and angles; directional lights ignore position,
// radius and angles.
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
  _:           u32,
}

// shadow_map value for a light without a shadow map.
NO_SHADOW :: 0xFFFFFFFF

// Pushed once per camera, read by every lighting pipeline.
LightingPushConstants :: struct {
  camera_index:     u32,
  gbuffer:          GBuffer,
  irradiance:       u32,
  prefilter:        u32,
  brdf_lut:         u32,
  environment:      u32,
  skybox_intensity: f32,
  skybox_blur:      f32,
}

DirectLightRenderer :: struct {
  pipelines: [LightType]vk.Pipeline,
  volumes:   [LightType]MeshAllocations,
}

// The volume each light type rasterizes, one instance per light, and the
// fragment shader shading it. Point and spot draw their volume's back faces
// where the scene lies in front of them; directional and ambient lights cover
// the screen with a clip-space triangle on the far plane, directional only
// where the scene lies in front of it.
@(private = "file")
DRAW_STATE := [LightType]struct {
  depth_compare: vk.CompareOp,
  cull:          vk.CullModeFlags,
  volume:        proc() -> mesh.Geometry,
  frag:          []u8,
} {
  .POINT       = {.GREATER_OR_EQUAL, {.FRONT}, proc() -> mesh.Geometry {return mesh.make_sphere()}, LIGHTING_SHADER_FRAG},
  .SPOT        = {.GREATER_OR_EQUAL, {.BACK}, proc() -> mesh.Geometry {return mesh.make_cone()}, LIGHTING_SHADER_FRAG},
  .DIRECTIONAL = {.GREATER, {.BACK}, fullscreen_triangle, LIGHTING_SHADER_FRAG},
  .AMBIENT     = {.ALWAYS, {.BACK}, fullscreen_triangle, AMBIENT_SHADER_FRAG},
}

// Clip-space triangle covering the screen, counter-clockwise in framebuffer
// space (clip-space y points down).
@(private = "file")
fullscreen_triangle :: proc() -> mesh.Geometry {
  vertices := make([]mesh.Vertex, 3)
  vertices[0].position = {-1, -1, 0}
  vertices[1].position = {-1, 3, 0}
  vertices[2].position = {3, -1, 0}
  indices := make([]u32, 3)
  indices[0], indices[1], indices[2] = 0, 1, 2
  return {vertices = vertices, indices = indices}
}

direct_light_init :: proc(r: ^Manager) -> (ret: vk.Result) {
  self := &r.internal.direct_light
  gctx := &r.gctx
  light_type_entry := vk.SpecializationMapEntry{constantID = 0, size = size_of(LightType)}
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ADDITIVE}
  defer if ret != .SUCCESS do direct_light_shutdown(r)
  for type in LightType {
    geometry := DRAW_STATE[type].volume()
    defer mesh.delete_geometry(geometry)
    self.volumes[type] = allocate_mesh(&r.mesh_manager, gctx, geometry) or_return
    light_type := type
    specialization := vk.SpecializationInfo {
      mapEntryCount = 1,
      pMapEntries   = &light_type_entry,
      dataSize      = size_of(light_type),
      pData         = &light_type,
    }
    raster := gpu.STANDARD_RASTERIZER
    raster.cullMode = DRAW_STATE[type].cull
    depth := gpu.READ_ONLY_DEPTH_STATE
    depth.depthCompareOp = DRAW_STATE[type].depth_compare
    self.pipelines[type] = gpu.create_graphics_pipeline(
      gctx,
      {
        vert = LIGHTING_SHADER_VERT,
        frag = DRAW_STATE[type].frag,
        specialization = &specialization,
        vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = POSITION_ATTRIBUTE_DESCRIPTIONS[:],
        topology = .TRIANGLE_LIST,
        raster = raster,
        depth = depth,
        blend = blend[:],
        color_formats = color_formats[:],
        depth_format = ATTACHMENTS[.DEPTH].format,
        layout = r.internal.scene.layout,
      },
    ) or_return
  }
  return .SUCCESS
}

direct_light_shutdown :: proc(r: ^Manager) {
  self := &r.internal.direct_light
  for p in self.pipelines do vk.DestroyPipeline(r.gctx.device, p, nil)
  for v in self.volumes do free_mesh(&r.mesh_manager, v)
  self^ = {}
}

// Record one camera's lighting: every light as one instance of its type's
// volume, additively over the cleared color image and depth-tested against
// the G-buffer depth. record_camera_passes orders it with the other passes.
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
  gpu.set_viewport_scissor(cmd, depth_texture.extent)
  bind_mesh_buffers(r, cmd)
  ambient := &r.ambient
  push := LightingPushConstants {
    camera_index     = cam_index,
    gbuffer          = gbuffer,
    irradiance       = texture_index(ambient.ibl.irradiance_cube),
    prefilter        = texture_index(ambient.ibl.prefilter_cube),
    brdf_lut         = texture_index(ambient.brdf_lut),
    environment      = texture_index(ambient.environment_map),
    skybox_intensity = ambient.skybox_intensity,
    skybox_blur      = ambient.skybox_blur,
  }
  push_constants(r, cmd, &push)
  for type in LightType {
    count := r.internal.light_count[type]
    if count == 0 do continue
    volume := self.volumes[type]
    vk.CmdBindPipeline(cmd, .GRAPHICS, self.pipelines[type])
    vk.CmdDrawIndexed(
      cmd,
      volume.indices.count,
      count,
      volume.indices.offset,
      i32(volume.vertices.offset),
      r.internal.light_first[type],
    )
  }
  vk.CmdEndRendering(cmd)
}
