package wgpu_backend

import rhi "../rhi"

import wgpu "vendor:wgpu"


@(private = "file")
LIGHTING_VS :: #load("shader/common.wgsl", string) + #load("shader/lighting_vs.wgsl", string)
@(private = "file")
LIGHTING_WGSL :: LIGHTING_VS + #load("shader/lighting.wgsl", string)
@(private = "file")
AMBIENT_WGSL :: LIGHTING_VS + #load("shader/lighting_ambient.wgsl", string)

@(private = "file")
LightingUniforms :: struct {
  camera_index:     u32,
  skybox_intensity: f32,
  skybox_blur:      f32,
  // the environment textures are bound; 0 when render has none
  has_environment:  u32,
  has_ibl:          u32,
}

// Point and spot draw the back faces of their volume mesh (FrameDesc.light_volumes);
// directional and ambient cover the screen with a far-plane triangle, directional only where
// the scene lies in front of it.
@(private = "file")
DRAW_STATE := [rhi.LightType]struct {
  depth_compare: wgpu.CompareFunction,
  cull:          wgpu.CullMode,
  source:        string,
} {
  .POINT       = {.GreaterEqual, .Front, LIGHTING_WGSL},
  .SPOT        = {.GreaterEqual, .Back, LIGHTING_WGSL},
  .DIRECTIONAL = {.Greater, .Back, LIGHTING_WGSL},
  .AMBIENT     = {.Always, .Back, AMBIENT_WGSL},
}

@(private = "file")
POSITION_ATTRIBUTE := wgpu.VertexAttribute{format = .Float32x3, offset = 0, shaderLocation = 0}

@(private)
lighting_init :: proc(b: ^Backend) {
  formats := [?]wgpu.TextureFormat{FORMATS[rhi.HDR_COLOR_FORMAT]}
  buffers := [?]wgpu.VertexBufferLayout{{stepMode = .Vertex, arrayStride = size_of(rhi.Vertex), attributeCount = 1, attributes = &POSITION_ATTRIBUTE}}
  for type in rhi.LightType {
    state := DRAW_STATE[type]
    constants := [?]wgpu.ConstantEntry{{key = "LIGHT_TYPE", value = f64(type)}}
    b.light_pipelines[type] = graphics_pipeline(
      b,
      {
        source = state.source,
        constants = constants[:],
        scene = .LIGHTING,
        textures = .LIGHTING,
        vertex_buffers = buffers[:],
        topology = .TriangleList,
        cull = state.cull,
        color_formats = formats[:],
        blend = &BLEND_ADDITIVE,
        depth = true,
        depth_compare = state.depth_compare,
        fragment = true,
      },
    )
  }
}

@(private)
lighting_record :: proc(b: ^Backend, desc: ^rhi.FrameDesc, encoder: wgpu.CommandEncoder, cam: ^rhi.FrameCamera) {
  color := wgpu.RenderPassColorAttachment {
    view       = b.textures[cam.attachments[.FINAL_IMAGE]].view,
    depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
    loadOp     = .Clear,
    storeOp    = .Store,
  }
  // read-only: volumes depth-test against it and shaders sample it
  depth := wgpu.RenderPassDepthStencilAttachment {
    view          = b.textures[cam.attachments[.DEPTH]].view,
    depthReadOnly = true,
  }
  rp := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color, depthStencilAttachment = &depth})
  defer {
    wgpu.RenderPassEncoderEnd(rp)
    wgpu.RenderPassEncoderRelease(rp)
  }
  u := LightingUniforms {
    camera_index     = cam.index,
    skybox_intensity = desc.skybox_intensity,
    skybox_blur      = desc.skybox_blur,
    has_environment  = u32(desc.environment_map != 0),
    has_ibl          = u32(desc.prefilter_cube != 0),
  }
  offset := uniform(b, &u)
  key := GroupKey{layout = .LIGHTING}
  key.textures = {
    cam.attachments[.NORMAL],
    cam.attachments[.ALBEDO],
    cam.attachments[.METALLIC_ROUGHNESS],
    cam.attachments[.EMISSIVE],
    cam.attachments[.DEPTH],
    0,
    desc.irradiance_cube,
    desc.prefilter_cube,
    desc.brdf_lut,
    desc.environment_map,
  }
  wgpu.RenderPassEncoderSetBindGroup(rp, 0, b.scene_groups[.LIGHTING])
  wgpu.RenderPassEncoderSetBindGroup(rp, 1, group(b, key))
  wgpu.RenderPassEncoderSetBindGroup(rp, 2, b.frame_group, {offset})
  mesh_buffers_bind(b, rp)
  first: u32
  for type in rhi.LightType {
    count := desc.light_count[type]
    defer first += count
    if count == 0 do continue
    wgpu.RenderPassEncoderSetPipeline(rp, b.light_pipelines[type])
    if volume := &desc.light_volumes[type]; volume.index_count > 0 {
      wgpu.RenderPassEncoderDrawIndexed(rp, volume.index_count, count, volume.first_index, volume.vertex_offset, first)
    } else {
      wgpu.RenderPassEncoderDraw(rp, 3, count, 0, first)
    }
  }
}
