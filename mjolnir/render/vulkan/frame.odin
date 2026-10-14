package vulkan_backend

import vk "vendor:vulkan"

// Every global memory dependency the frame records, by the work it orders: a barrier is
// (writes made, reads that must see them) between two stage sets.
@(private)
Barrier :: enum {
  // a fill or dispatch writes what a later dispatch reads or writes
  FILL_TO_COMPUTE,
  // colors a pass wrote are sampled by a later one (render-to-texture, post-process input)
  COLOR_TO_SAMPLE,
  GBUFFER_TO_LIGHTING,
  LIGHTING_TO_FORWARD,
  FORWARD_TO_COMPUTE,
  SHADOW_TO_LIGHTING,
  CULL_TO_INDIRECT,
  CULL_TO_COPY,
  INDIRECT_TO_FILL,
  FILL_TO_CULL,
  // the previous simulation and this frame's draws use what the particle pass rewrites
  PARTICLES_TO_FILL,
  POST_PASS,
}

@(private)
BARRIERS := [Barrier]struct {
  src_access, dst_access: vk.AccessFlags2,
  src_stage, dst_stage:   vk.PipelineStageFlags2,
} {
  .FILL_TO_COMPUTE = {{.SHADER_WRITE, .TRANSFER_WRITE}, {.SHADER_READ, .SHADER_WRITE}, {.COMPUTE_SHADER, .TRANSFER}, {.COMPUTE_SHADER}},
  .COLOR_TO_SAMPLE = {{.COLOR_ATTACHMENT_WRITE}, {.SHADER_READ}, {.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER}},
  .GBUFFER_TO_LIGHTING = {
    {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ, .DEPTH_STENCIL_ATTACHMENT_READ},
    {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
  },
  .LIGHTING_TO_FORWARD = {
    {.SHADER_WRITE, .COLOR_ATTACHMENT_WRITE},
    {.INDIRECT_COMMAND_READ, .SHADER_READ, .DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
    {.FRAGMENT_SHADER, .COMPUTE_SHADER, .COLOR_ATTACHMENT_OUTPUT},
    {.DRAW_INDIRECT, .VERTEX_SHADER, .EARLY_FRAGMENT_TESTS, .COLOR_ATTACHMENT_OUTPUT},
  },
  .FORWARD_TO_COMPUTE = {{.DEPTH_STENCIL_ATTACHMENT_WRITE}, {.SHADER_READ}, {.LATE_FRAGMENT_TESTS}, {.COMPUTE_SHADER, .FRAGMENT_SHADER}},
  .SHADOW_TO_LIGHTING = {{.DEPTH_STENCIL_ATTACHMENT_WRITE}, {.SHADER_READ}, {.LATE_FRAGMENT_TESTS}, {.FRAGMENT_SHADER}},
  .CULL_TO_INDIRECT = {{.SHADER_WRITE}, {.INDIRECT_COMMAND_READ}, {.COMPUTE_SHADER}, {.DRAW_INDIRECT}},
  .CULL_TO_COPY = {{.SHADER_WRITE}, {.TRANSFER_READ}, {.COMPUTE_SHADER, .DRAW_INDIRECT}, {.TRANSFER}},
  .INDIRECT_TO_FILL = {{}, {}, {.DRAW_INDIRECT}, {.TRANSFER}},
  .FILL_TO_CULL = {{.TRANSFER_WRITE}, {.SHADER_READ, .SHADER_WRITE}, {.TRANSFER}, {.COMPUTE_SHADER}},
  .PARTICLES_TO_FILL = {
    {.SHADER_WRITE},
    {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
    {.DRAW_INDIRECT, .VERTEX_SHADER, .COMPUTE_SHADER},
    {.COMPUTE_SHADER, .TRANSFER},
  },
  .POST_PASS = {
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ, .COLOR_ATTACHMENT_WRITE},
    {.COLOR_ATTACHMENT_OUTPUT, .FRAGMENT_SHADER},
    {.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
  },
}

@(private)
barrier :: proc(cmd: vk.CommandBuffer, b: Barrier) {
  t := &BARRIERS[b]
  memory_barrier(cmd, t.src_access, t.dst_access, t.src_stage, t.dst_stage)
}

@(private)
record_compute_commands :: proc(b: ^Backend, desc: ^FrameDesc, cmd: vk.CommandBuffer) {
  // ordering against graphics N-1 is in submit_queue_and_present
  vk.CmdBindPipeline(cmd, .COMPUTE, b.pipelines[.DEPTH_REDUCE])
  for &cam in desc.live_cameras {
    draw_lists_clear(b, cmd, cam.next_slot)
    if !cam.ready do continue
    occlusion_build_pyramid(b, cmd, cam.slot, cam.pyramid, u32(cam.prev_depth))
  }
  barrier(cmd, .FILL_TO_COMPUTE)
  occlusion_cull(b, cmd, desc.node_count, CAMERA_VIEW_BASE + 1, desc.camera_view_count)
}

// Phase by phase across cameras (G-buffer, lighting, forward) so one barrier
// serves every camera; render scopes cannot hold barriers.
@(private)
record_camera_passes :: proc(b: ^Backend, desc: ^FrameDesc, frame_index: u32) {
  cmd := b.command_buffers[frame_index]
  if len(desc.live_cameras) == 0 do return
  discards := make([dynamic]ImageDiscard, context.temp_allocator)
  for &cam in desc.live_cameras {
    for a in AttachmentType do append(&discards, attachment_discard(texture_image(b, cam.attachments[a])))
  }
  barrier(cmd, .CULL_TO_INDIRECT)
  // render-to-texture: a material may sample last frame's lit image
  barrier(cmd, .COLOR_TO_SAMPLE)
  image_discard_barrier(cmd, ..discards[:])
  for &cam in desc.live_cameras do material_pass_record(b, frame_index, &cam, .GBUFFER)
  barrier(cmd, .GBUFFER_TO_LIGHTING)
  for &cam in desc.live_cameras do lighting_record(b, desc, frame_index, &cam)
  barrier(cmd, .LIGHTING_TO_FORWARD)
  for &cam in desc.live_cameras do material_pass_record(b, frame_index, &cam, .FORWARD)
  barrier(cmd, .FORWARD_TO_COMPUTE)
}

// PRESENT_SRC is the one layout transition unified image layouts do not cover.
@(private)
record_frame :: proc(b: ^Backend, desc: ^FrameDesc, frame_index: u32) -> vk.Result {
  cmd := b.command_buffers[frame_index]
  sc := &b.swapchain
  swapchain_image, swapchain_view := sc.images[sc.image_index], sc.views[sc.image_index]
  begin_record(cmd) or_return
  bind_scene_sets(b, cmd, .GRAPHICS, frame_index)
  bind_scene_sets(b, cmd, .COMPUTE, frame_index)
  record_uploads(&b.gctx, cmd)
  shadow_record(b, desc, frame_index)

  record_camera_passes(b, desc, frame_index)

  if desc.main_live >= 0 {
    main_cam := &desc.live_cameras[desc.main_live]
    draw_lists_copy_counts(b, cmd, main_cam.slot, &b.draw_count_readback[frame_index])
    barrier(cmd, .COLOR_TO_SAMPLE)
    image_discard_barrier(
      cmd,
      {swapchain_image, {.COLOR}, {.COLOR_ATTACHMENT_WRITE}, {.COLOR_ATTACHMENT_OUTPUT}},
    )
    post_process_record(b, desc, frame_index, sc.extent, swapchain_view, main_cam)
    debug_line_record(b, desc, frame_index, main_cam, swapchain_view, sc.extent)
  }
  overlay_record(b, desc, cmd, swapchain_view, sc.extent, frame_index)

  // after drawing: the next frame draws what this simulates
  particles_simulate(b, cmd, &desc.particle_params)
  // separate submission, on the async compute queue when there is one
  compute_cmd := b.compute_command_buffers[frame_index]
  begin_record(compute_cmd) or_return
  bind_scene_sets(b, compute_cmd, .COMPUTE, frame_index)
  record_compute_commands(b, desc, compute_cmd)
  vk.EndCommandBuffer(compute_cmd) or_return

  present_barrier(cmd, swapchain_image)
  vk.EndCommandBuffer(cmd) or_return
  return .SUCCESS
}
