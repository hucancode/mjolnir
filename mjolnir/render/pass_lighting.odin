package render

import "rhi"

// Deferred lighting: one compute dispatch per camera reads the G-buffer and writes the
// camera's lit image (FINAL_IMAGE) whole, a group per LIGHTING_TILE square tile. Each group
// walks the light placements once and lists the visible lights reaching its tile (the point
// and spot ones whose sphere meets it), so a pixel reads the G-buffer once however many lights
// cover it. Directional lights reach every tile, so every tile lists them.
// The image-based light is scaled by the camera's ambient occlusion image, when it has one.
// The image is a storage image: bindless at its storage view, or a group-3 bind group per image
// (WebGPU).

@(private = "file")
LIGHTING_TILE :: 16

// Matches the push block of the lighting shaders (and, in WebGPU, their uniform struct).
@(private = "file")
LightingPush :: struct {
  camera_index:      u32,
  irradiance:        u32,
  prefilter:         u32,
  brdf_lut:          u32,
  environment:       u32,
  skybox_intensity:  f32,
  skybox_blur:       f32,
  output_index:      u32,
  // rows of the light placement table
  light_count:       u32,
  ibl_intensity:     f32,
  // the G-buffer's textures; ambient occlusion 0 when the camera runs none
  normal_index:             u32,
  albedo_index:             u32,
  metallic_roughness_index: u32,
  emissive_index:           u32,
  depth_index:              u32,
  ambient_occlusion_index:  u32,
}

// WebGPU: group 3 of the lighting dispatch, the image it writes.
@(private = "file")
LIGHTING_OUTPUT_LAYOUT :: GpuLayoutKey{count = 1, compute = true, kinds = {0 = .STORAGE_TEXTURE}, formats = {0 = HDR_COLOR_FORMAT}}

@(private)
lighting_init :: proc(self: ^Renderer) -> bool {
  output_layout: rhi.BindLayout
  when !BINDLESS do output_layout = gpu_layout(self, LIGHTING_OUTPUT_LAYOUT) or_return
  self.pipelines[.LIGHTING] = dev.compute_pipeline_create(
    &self.gpu,
    {
      shader_source("lighting"),
      pipeline_layout(self, .LIGHTING, .LIGHTING, output_layout),
    },
  ) or_return
  return true
}

// Camera g.arg's lit image: its uses are the normals, albedo, metallic-roughness, emissive,
// depth, ambient occlusion (or none), the shadow atlas, then the image it writes.
@(private)
lighting_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, g: GraphPass) {
  cam := g.arg
  gbuffer: [6]TextureHandle
  for &t, i in gbuffer do t = pass_texture(self, g, i)
  output := pass_texture(self, g, 7)
  group: rhi.BindGroup
  when !BINDLESS {
    resources := [1]rhi.BindResource{rhi.TextureView{output, 0}}
    ok: bool
    group, ok = cached_group(self, output, gpu_layout(self, LIGHTING_OUTPUT_LAYOUT) or_else 0, resources[:])
    if !ok do return
  }
  push := LightingPush {
    camera_index      = cam,
    irradiance        = u32(self.environment.irradiance),
    prefilter         = u32(self.environment.prefilter),
    brdf_lut          = u32(self.brdf_lut),
    environment       = u32(self.environment.image),
    skybox_intensity  = self.skybox_intensity,
    skybox_blur       = self.skybox_blur,
    light_count       = self.slots[.LIGHT_PLACEMENTS].high_water,
    ibl_intensity     = self.ibl_intensity,
    normal_index      = u32(gbuffer[0]),
    albedo_index      = u32(gbuffer[1]),
    metallic_roughness_index = u32(gbuffer[2]),
    emissive_index    = u32(gbuffer[3]),
    depth_index       = u32(gbuffer[4]),
    ambient_occlusion_index = u32(gbuffer[5]),
  }
  when BINDLESS do push.output_index = storage_view(self, output)
  pipeline_bind(
    self,
    cmd,
    self.pipelines[.LIGHTING],
    .LIGHTING,
    f,
    &push,
    .LIGHTING,
    gbuffer[0],
    gbuffer[1],
    gbuffer[2],
    gbuffer[3],
    gbuffer[4],
    0,
    self.environment.irradiance,
    self.environment.prefilter,
    self.brdf_lut,
    self.environment.image,
    gbuffer[5],
  )
  if group != 0 do dev.cmd_bind_group(&self.gpu, cmd, 3, group)
  groups := (self.camera_targets[cam].extent + LIGHTING_TILE - 1) / LIGHTING_TILE
  dev.cmd_dispatch(&self.gpu, cmd, groups.x, groups.y, 1)
}
