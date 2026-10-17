package render

import "rhi"

// Deferred lighting: one compute dispatch per camera reads the G-buffer and writes the
// camera's lit image (FINAL_IMAGE) whole, a group per LIGHTING_TILE square tile. Each group
// walks the light placements once and lists the visible lights reaching its tile (every
// directional one, the point and spot ones whose sphere meets it), so a pixel reads the
// G-buffer once however many lights cover it (shader/vulkan/lighting/lighting.comp, shader/wgpu/lighting.wgsl).
// The image is a storage image: bindless at LIT_STORAGE_BASE + the camera's pyramid slot
// (pyramids_bind), or a group-3 bind group per image (WebGPU).

@(private = "file")
LIGHTING_TILE :: 16

// Storage image slots of the lit images, one per pyramid slot, after the IBL's (Vulkan).
@(private)
LIT_STORAGE_BASE :: PRECOMPUTE_STORAGE_BASE + PRECOMPUTE_DISPATCHES

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
  _:                [2]u32,
}

@(private)
lighting_init :: proc(self: ^Renderer) -> bool {
  when !BINDLESS {
    entries := [1]rhi.BindEntry{{kind = .STORAGE_TEXTURE, stages = {.COMPUTE}, format = HDR_COLOR_FORMAT}}
    self.lighting_output_layout = dev.bind_layout_create(&self.gpu, {entries = entries[:]}) or_return
  }
  self.lighting_pipeline = dev.compute_pipeline_create(
    &self.gpu,
    {
      {spirv = {comp = spirv("shader/vulkan/lighting/lighting.spv")}, wgsl = wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/lighting.wgsl"))},
      pipeline_layout(self, .LIGHTING, .LIGHTING, self.lighting_output_layout),
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
    cached: bool
    group, cached = self.lighting_output_groups[output]
    if !cached {
      resources := [1]rhi.BindResource{rhi.TextureView{output, 0}}
      ok: bool
      group, ok = dev.bind_group_create(&self.gpu, {layout = self.lighting_output_layout, resources = resources[:]})
      if !ok do return
      self.lighting_output_groups[output] = group
    }
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
    light_count      = self.light_placement_slots.high_water,
    ibl_intensity    = self.ibl_intensity,
  }
  dev.cmd_begin_compute(&self.gpu, cmd)
  defer dev.cmd_end_compute(&self.gpu, cmd)
  pipeline_bind(
    self,
    cmd,
    self.lighting_pipeline,
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
