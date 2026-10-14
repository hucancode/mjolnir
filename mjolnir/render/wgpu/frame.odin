package wgpu_backend

import "core:log"
import wgpu "vendor:wgpu"

// frame records, submits and presents the frame render described, in one command encoder:
// uploads, cull, shadows, each camera's G-buffer, lighting and forward passes, post-process,
// debug lines, overlay, then the particle simulation the next frame draws. Queue order is the
// only sync. RESIZE: the surface no longer matches the window.
frame :: proc(b: ^Backend, desc: ^FrameDesc) -> (submitted: bool, status: FrameStatus) {
  if !b.up do return false, .OK
  events_process(b)
  if window_size(b) != b.surface_extent do return false, .RESIZE
  surface_texture := surface_texture_get(b)
  #partial switch surface_texture.status {
  case .SuccessOptimal, .SuccessSuboptimal:
  case .Timeout, .Outdated, .Lost, .Occluded:
    if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
    return false, .RESIZE
  case:
    log.errorf("WebGPU surface texture: %v", surface_texture.status)
    return false, .ERROR
  }
  output := wgpu.TextureCreateView(surface_texture.texture, &{format = b.surface_view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1})
  defer {
    wgpu.TextureViewRelease(output)
    wgpu.TextureRelease(surface_texture.texture)
  }
  tables_upload(b, desc)
  overlay_upload(b, desc)
  candidates_collect(b, desc)
  shadow_atlas_reserve(b, desc.shadow_view_count)
  encoder := wgpu.DeviceCreateCommandEncoder(b.device)
  cull_record(b, desc, encoder)
  shadow_record(b, desc, encoder)
  for &cam in desc.live_cameras do material_pass_record(b, desc, encoder, &cam, .GBUFFER)
  for &cam in desc.live_cameras do lighting_record(b, desc, encoder, &cam)
  for &cam in desc.live_cameras do material_pass_record(b, desc, encoder, &cam, .FORWARD)
  if desc.main_live >= 0 {
    main_cam := &desc.live_cameras[desc.main_live]
    draw_count_record(b, encoder, main_cam.next_slot)
    post_process_record(b, desc, encoder, output, main_cam)
    debug_line_record(b, desc, encoder, main_cam, output)
  } else {
    clear_output(encoder, output)
  }
  overlay_record(b, desc, encoder, output)
  particles_simulate(b, encoder, &desc.particle_params)
  commands := wgpu.CommandEncoderFinish(encoder)
  uniforms_flush(b)
  wgpu.QueueSubmit(b.queue, {commands})
  wgpu.CommandBufferRelease(commands)
  wgpu.CommandEncoderRelease(encoder)
  wgpu.SurfacePresent(b.surface)
  b.frame_serial += 1
  draw_count_map(b)
  for g in b.frame_groups do wgpu.BindGroupRelease(g)
  clear(&b.frame_groups)
  return true, .OK
}

// Without a main camera nothing else covers the presented image.
@(private = "file")
clear_output :: proc(encoder: wgpu.CommandEncoder, output: wgpu.TextureView) {
  color := wgpu.RenderPassColorAttachment{view = output, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store}
  rp := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color})
  wgpu.RenderPassEncoderEnd(rp)
  wgpu.RenderPassEncoderRelease(rp)
}
