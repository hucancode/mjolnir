package render

import "rhi"

// Deferred lighting: one compute dispatch per camera reads the G-buffer and writes the
// camera's lit image (FINAL_IMAGE) whole, a group per LIGHTING_TILE square tile. Each group
// lists the point and spot lights reaching its tile, so a pixel reads the G-buffer once
// however many lights cover it (shader/vulkan/lighting/lighting.comp, shader/wgpu/lighting.wgsl).
// The image is a storage image: bindless at LIT_STORAGE_BASE + the camera's pyramid slot
// (pyramids_bind), or a group-3 bind group per image (WebGPU).

@(private = "file")
LIGHTING_TILE :: 16

// Storage image slots of the lit images, one per pyramid slot, after the IBL's (Vulkan).
@(private)
LIT_STORAGE_BASE :: PRECOMPUTE_STORAGE_BASE + PRECOMPUTE_DISPATCHES

@(private)
LightingState :: struct {
  pipeline:      rhi.Pipeline,
  // WebGPU: group 3, the image the dispatch writes, a group per image
  output_layout: rhi.BindLayout,
  output_groups: map[TextureHandle]rhi.BindGroup,
}

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
  // lights are sorted by type: each type's range of the light table
  light_count:      [LightType]u32,
}
// a uniform vec4u in WebGPU
#assert(offset_of(LightingPush, light_count) % 16 == 0)

@(private)
lighting_init :: proc(r: ^Renderer) -> bool {
  l := &r.lighting
  if !r.res.caps.bindless {
    entries := [1]rhi.BindEntry{{kind = .STORAGE_TEXTURE, stages = {.COMPUTE}, format = HDR_COLOR_FORMAT}}
    l.output_layout = dev.bind_layout_create(&r.gpu, {entries = entries[:]}) or_return
  }
  l.pipeline = dev.compute_pipeline_create(
    &r.gpu,
    {
      {spirv = {comp = spirv("shader/vulkan/lighting/lighting.spv")}, wgsl = wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/lighting.wgsl"))},
      pipeline_layout(r, .LIGHTING, .LIGHTING, l.output_layout),
    },
  ) or_return
  return true
}

@(private)
lighting_shutdown :: proc(r: ^Renderer) {
  delete(r.lighting.output_groups)
}

// Drops the output groups, made again on use: an image they name changed.
@(private)
lighting_groups_clear :: proc(r: ^Renderer) {
  l := &r.lighting
  for _, g in l.output_groups do dev.bind_group_retire(&r.gpu, g)
  clear(&l.output_groups)
}

@(private)
lighting_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32, cam: ^FrameCamera) {
  l := &r.lighting
  output := cam.attachments[.FINAL_IMAGE]
  group: rhi.BindGroup
  if !r.res.caps.bindless {
    cached: bool
    group, cached = l.output_groups[output]
    if !cached {
      resources := [1]rhi.BindResource{rhi.TextureView{output, 0}}
      ok: bool
      group, ok = dev.bind_group_create(&r.gpu, {layout = l.output_layout, resources = resources[:]})
      if !ok do return
      l.output_groups[output] = group
    }
  }
  push := LightingPush {
    camera_index     = cam.index,
    irradiance       = u32(r.irradiance_cube),
    prefilter        = u32(r.prefilter_cube),
    brdf_lut         = u32(r.brdf_lut),
    environment      = u32(r.environment_map),
    skybox_intensity = r.skybox_intensity,
    skybox_blur      = r.skybox_blur,
    output_index     = LIT_STORAGE_BASE + cam.slot,
    light_count      = r.light_count,
  }
  dev.cmd_begin_compute(&r.gpu, cmd)
  defer dev.cmd_end_compute(&r.gpu, cmd)
  pipeline_bind(
    r,
    cmd,
    l.pipeline,
    .LIGHTING,
    f,
    &push,
    .LIGHTING,
    cam.attachments[.NORMAL],
    cam.attachments[.ALBEDO],
    cam.attachments[.METALLIC_ROUGHNESS],
    cam.attachments[.EMISSIVE],
    cam.attachments[.DEPTH],
    0,
    r.irradiance_cube,
    r.prefilter_cube,
    r.brdf_lut,
    r.environment_map,
  )
  if group != 0 do dev.cmd_bind_group(&r.gpu, cmd, 3, group)
  groups := (cam.extent + LIGHTING_TILE - 1) / LIGHTING_TILE
  dev.cmd_dispatch(&r.gpu, cmd, groups.x, groups.y, 1)
}
