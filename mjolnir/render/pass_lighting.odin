package render

import "rhi"

// Deferred lighting: one compute dispatch per camera reads the G-buffer and writes the
// camera's lit image (FINAL_IMAGE) whole, a group per LIGHTING_TILE square tile. Each group
// walks the light placements once and lists the visible lights reaching its tile (the point
// and spot ones whose sphere meets it), so a pixel reads the G-buffer once however many lights
// cover it. The sun is not listed: every pixel adds it from the push (shader/lighting.slang).
// The image is a storage image: bindless at LIT_STORAGE_BASE + the camera's pyramid slot
// (pyramids_bind), or a group-3 bind group per image (WebGPU).

@(private = "file")
LIGHTING_TILE :: 16

// Storage image slots of the lit images, one per pyramid slot, after the IBL's (Vulkan).
@(private)
LIT_STORAGE_BASE :: PRECOMPUTE_STORAGE_BASE + PRECOMPUTE_TARGETS

// Matches the push block of the lighting shaders (and, in WebGPU, their uniform struct).
@(private = "file")
LightingPush :: struct {
  camera_index:     u32,
  irradiance:       u32,
  prefilter:        u32,
  brdf_lut:         u32,
  environment:      u32,
  skybox_intensity: f32,
  skybox_blur:      f32,
  output_index:     u32,
  // rows of the light placement table
  light_count:      u32,
  ibl_intensity:    f32,
  // view of the sun's first shadow cascade, 0 for none
  sun_shadow_map:   u32,
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

@(private)
lighting_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32) {
  images := &self.camera_targets[cam].images
  group: rhi.BindGroup
  when !BINDLESS {
    output := images[.FINAL_IMAGE][f]
    resources := [1]rhi.BindResource{rhi.TextureView{output, 0}}
    ok: bool
    group, ok = cached_group(self, output, gpu_layout(self, LIGHTING_OUTPUT_LAYOUT) or_else 0, resources[:])
    if !ok do return
  }
  push := LightingPush {
    camera_index     = cam,
    irradiance       = u32(self.irradiance_cube),
    prefilter        = u32(self.prefilter_cube),
    brdf_lut         = u32(self.brdf_lut),
    environment      = u32(self.environment_map),
    skybox_intensity = self.skybox_intensity,
    skybox_blur      = self.skybox_blur,
    output_index     = LIT_STORAGE_BASE + camera_slot(cam) + f,
    light_count      = self.slots[.LIGHT_PLACEMENTS].high_water,
    ibl_intensity    = self.ibl_intensity,
    sun_shadow_map   = self.sun_shadow_map,
  }
  dev.cmd_begin_compute(&self.gpu, cmd)
  defer dev.cmd_end_compute(&self.gpu, cmd)
  pipeline_bind(
    self,
    cmd,
    self.pipelines[.LIGHTING],
    .LIGHTING,
    f,
    &push,
    .LIGHTING,
    images[.NORMAL][f],
    images[.ALBEDO][f],
    images[.METALLIC_ROUGHNESS][f],
    images[.EMISSIVE][f],
    images[.DEPTH][f],
    0,
    self.irradiance_cube,
    self.prefilter_cube,
    self.brdf_lut,
    self.environment_map,
  )
  if group != 0 do dev.cmd_bind_group(&self.gpu, cmd, 3, group)
  groups := (self.camera_targets[cam].extent + LIGHTING_TILE - 1) / LIGHTING_TILE
  dev.cmd_dispatch(&self.gpu, cmd, groups.x, groups.y, 1)
}
