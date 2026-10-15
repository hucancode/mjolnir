package render

import "rhi"

@(private)
LightingState :: struct {
  pipelines: [LightType]rhi.Pipeline,
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
}

// Point and spot draw the back faces of their volume mesh (FrameDesc.light_volumes);
// directional and ambient cover the screen with a far-plane triangle, directional only where
// the scene lies in front of it.
@(private = "file")
DRAW_STATE := [LightType]struct {
  depth_compare: rhi.CompareOp,
  cull:          rhi.CullMode,
} {
  .POINT       = {.GREATER_EQUAL, .FRONT},
  .SPOT        = {.GREATER_EQUAL, .BACK},
  .DIRECTIONAL = {.GREATER, .BACK},
  .AMBIENT     = {.ALWAYS, .BACK},
}

@(private)
lighting_init :: proc(r: ^Renderer) -> bool {
  common := wgsl("shader/wgpu/common.wgsl")
  vertex := wgsl_join(common, wgsl("shader/wgpu/lighting_vs.wgsl"))
  position := [?]rhi.VertexAttribute{{location = 0, format = .F32X3, offset = u32(offset_of(Vertex, position))}}
  streams := [?]rhi.VertexBuffer{{stride = size_of(Vertex), attributes = position[:]}}
  formats := [?]TextureFormat{HDR_COLOR_FORMAT}
  for type in LightType {
    ambient := type == .AMBIENT
    constants := [?]u32{u32(type)}
    desc := rhi.GraphicsPipelineDesc {
      shader = {
        spirv = {
          vert = spirv("shader/vulkan/lighting/vert.spv"),
          frag = spirv("shader/vulkan/lighting_ambient/frag.spv") if ambient else spirv("shader/vulkan/lighting/frag.spv"),
        },
        wgsl = wgsl_join(vertex, wgsl("shader/wgpu/lighting_ambient.wgsl") if ambient else wgsl("shader/wgpu/lighting.wgsl")),
      },
      layout = pipeline_layout(r, .LIGHTING, .LIGHTING),
      vertex = streams[:],
      cull = DRAW_STATE[type].cull,
      color_formats = formats[:],
      blend = .ADDITIVE,
      // read-only: volumes depth-test against the scene depth, shaders sample it
      depth = rhi.DepthState{compare = DRAW_STATE[type].depth_compare},
      constants = constants[:],
    }
    r.lighting.pipelines[type] = dev.graphics_pipeline_create(&r.gpu, desc) or_return
  }
  return true
}

@(private)
lighting_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32, cam: ^FrameCamera) {
  colors := [1]rhi.ColorTarget{{texture = cam.attachments[.FINAL_IMAGE], load = .CLEAR, clear = {0, 0, 0, 1}}}
  dev.cmd_begin_pass(&r.gpu, cmd, {colors = colors[:], depth = rhi.DepthTarget{texture = cam.attachments[.DEPTH], load = .LOAD, read_only = true}})
  push := LightingPush {
    camera_index     = cam.index,
    irradiance       = u32(r.irradiance_cube),
    prefilter        = u32(r.prefilter_cube),
    brdf_lut         = u32(r.brdf_lut),
    environment      = u32(r.environment_map),
    skybox_intensity = r.skybox_intensity,
    skybox_blur      = r.skybox_blur,
  }
  pipeline_bind(
    r,
    cmd,
    r.lighting.pipelines[.POINT],
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
  mesh_buffers_bind(r, cmd)
  first: u32
  for type in LightType {
    count := r.light_count[type]
    defer first += count
    if count == 0 do continue
    dev.cmd_bind_pipeline(&r.gpu, cmd, r.lighting.pipelines[type])
    if volume := &r.light_volumes[type]; volume.index_count > 0 {
      dev.cmd_draw_indexed(&r.gpu, cmd, volume.index_count, count, volume.first_index, volume.vertex_offset, first)
    } else {
      dev.cmd_draw(&r.gpu, cmd, 3, count, 0, first)
    }
  }
  dev.cmd_end_pass(&r.gpu, cmd)
}
