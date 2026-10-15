package vulkan_backend

import rhi "../rhi"

import vk "vendor:vulkan"

// Depth pyramids and draw lists live in slots render assigns: a pyramid per camera and frame
// in flight; a draw-list slot per camera and frame in flight, plus one per frame for the
// shadow views.
MAX_PYRAMID_SLOTS :: rhi.MAX_ACTIVE_CAMERAS * FRAMES_IN_FLIGHT
MAX_DRAW_LIST_SLOTS :: (rhi.MAX_ACTIVE_CAMERAS + 1) * FRAMES_IN_FLIGHT

// Mip 0 texels a depth pyramid group reduces per side (depth_reduce.comp).
@(private = "file")
PYRAMID_TILE :: 32

// Pyramid slot `slot` owns counter `slot` and storage images [slot * MAX_DEPTH_MIPS_LEVEL,
// (slot + 1) * MAX_DEPTH_MIPS_LEVEL) (Backend.pyramid_views[slot]).

@(private = "file")
CullPushConstants :: struct {
  node_count: u32,
  first_view: u32,
}

@(private = "file")
DepthReducePushConstants :: struct {
  depth_index: u32,
  mip_count:   u32,
  group_count: u32,
  slot:        u32,
}

// mips a depth pyramid may have
@(private)
MAX_DEPTH_MIPS_LEVEL :: 16

@(private)
occlusion_init :: proc(b: ^Backend) -> vk.Result {
  layout := b.scene.layout
  b.pipelines[.CULL] = create_compute_pipeline(&b.gctx, #load("shader/occlusion_culling/cull.spv"), layout) or_return
  b.pipelines[.DEPTH_REDUCE] = create_compute_pipeline(&b.gctx, #load("shader/occlusion_culling/depth_reduce.spv"), layout) or_return
  return .SUCCESS
}

// pyramid_create makes pyramid slot `slot` build into `pyramid`, a mipmapped R32F storage
// texture render made: a storage view per mip, which enter the storage image array at the
// slot's next frame (occlusion_bind_pyramid), once no frame in flight reads its previous views.
pyramid_create :: proc(b: ^Backend, slot: u32, pyramid: rhi.TextureHandle) -> bool {
  gctx := &b.gctx
  b.pyramid_bound[slot] = false
  img := texture_image(b, pyramid)
  assert(img.mip_levels <= MAX_DEPTH_MIPS_LEVEL)
  queue_image_init(gctx, {img.image, {.COLOR}, {.SHADER_READ, .SHADER_WRITE}, {.COMPUTE_SHADER}})
  for mip in 0 ..< img.mip_levels {
    view, res := image_create_view(gctx.device, img, .D2, base_mip = mip)
    check(res, "Depth pyramid view") or_return
    b.pyramid_views[slot][mip] = view
  }
  return true
}

// Call when no frame in flight reads the slot.
@(private)
occlusion_bind_pyramid :: proc(b: ^Backend, slot: u32) {
  if b.pyramid_bound[slot] do return
  b.pyramid_bound[slot] = true
  for view, mip in b.pyramid_views[slot] {
    if view == 0 do break
    write_descriptor(
      &b.gctx,
      b.scene.bindless_set,
      BINDING_STORAGE_IMAGES,
      slot * MAX_DEPTH_MIPS_LEVEL + u32(mip),
      .STORAGE_IMAGE,
      vk.DescriptorImageInfo{imageView = view, imageLayout = .GENERAL},
    )
  }
}

// pyramid_destroy releases slot's views once no frame in flight uses them.
pyramid_destroy :: proc(b: ^Backend, slot: u32) {
  for view in b.pyramid_views[slot] do if view != 0 do defer_destroy(&b.gctx, view)
  b.pyramid_views[slot] = {}
  b.pyramid_bound[slot] = false
}

// The caller binds the reduce pipeline and orders the dispatch before the cull.
@(private)
occlusion_build_pyramid :: proc(b: ^Backend, cmd: vk.CommandBuffer, slot: u32, pyramid: rhi.TextureHandle, depth_index: u32) {
  img := texture_image(b, pyramid)
  if img == nil || !b.pyramid_bound[slot] do return
  groups := [2]u32 {
    (img.extent.width + PYRAMID_TILE - 1) / PYRAMID_TILE,
    (img.extent.height + PYRAMID_TILE - 1) / PYRAMID_TILE,
  }
  push := DepthReducePushConstants {
    depth_index = depth_index,
    mip_count   = img.mip_levels,
    group_count = groups.x * groups.y,
    slot        = slot,
  }
  push_constants(b, cmd, &push)
  vk.CmdDispatch(cmd, groups.x, groups.y, 1)
}

// The caller zeroes the counts first (draw_lists_clear) and orders the clear before this.
@(private)
occlusion_cull :: proc(b: ^Backend, cmd: vk.CommandBuffer, node_count, first_view, view_count: u32) {
  if node_count == 0 || view_count == 0 do return
  vk.CmdBindPipeline(cmd, .COMPUTE, b.pipelines[.CULL])
  push := CullPushConstants {
    node_count = node_count,
    first_view = first_view,
  }
  push_constants(b, cmd, &push)
  vk.CmdDispatch(cmd, (node_count + 63) / 64, view_count, 1)
}

// counts at the head of a buffer, one per list; commands follow
@(private)
DRAW_LIST_HEADER :: 8
#assert(len(rhi.MaterialType) <= DRAW_LIST_HEADER)
@(private)
DRAW_COMMAND_SIZE :: size_of(vk.DrawIndexedIndirectCommand)

// Draw lists are indirect draw lists in Backend.draw_lists[slot], one device-local buffer per
// bindless draw-list slot holding up to DRAW_LIST_HEADER lists of `capacity` draws; list i has its
// count at u32 i. A slot's lists hold garbage until its first cull. Without drawIndirectCount
// every command is drawn, so a clear also zeroes the commands (instanceCount 0 draws nothing).

// draw_list_create makes draw-list slot `slot`: `lists` indirect draw lists of `capacity` draws.
draw_list_create :: proc(b: ^Backend, slot, lists, capacity: u32) -> bool {
  assert(lists <= DRAW_LIST_HEADER)
  size := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(lists) * int(capacity) * DRAW_COMMAND_SIZE)
  buffer, res := buffer_create(&b.gctx, size, {.STORAGE_BUFFER, .INDIRECT_BUFFER}, host_visible = false)
  check(res, "Draw lists") or_return
  b.draw_lists[slot] = buffer
  b.draw_list_capacity[slot] = capacity
  write_descriptor(&b.gctx, b.scene.bindless_set, BINDING_DRAW_LISTS, slot, .STORAGE_BUFFER, buffer_info(&b.draw_lists[slot]))
  return true
}

// draw_list_destroy releases slot's draw lists once no frame in flight uses them.
draw_list_destroy :: proc(b: ^Backend, slot: u32) {
  buffer := &b.draw_lists[slot]
  if buffer.buffer != 0 do defer_destroy(&b.gctx, buffer^)
  buffer^ = {}
  b.draw_list_capacity[slot] = 0
}

// Order earlier indirect reads before it and the cull after it.
@(private)
draw_lists_clear :: proc(b: ^Backend, cmd: vk.CommandBuffer, slot: u32) {
  size := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32)) if b.gctx.draw_indirect_count else vk.DeviceSize(vk.WHOLE_SIZE)
  vk.CmdFillBuffer(cmd, b.draw_lists[slot].buffer, 0, size, 0)
}

// Call inside a render scope.
@(private)
draw_lists_draw :: proc(b: ^Backend, cmd: vk.CommandBuffer, slot: u32, list: u32) {
  buffer := b.draw_lists[slot].buffer
  capacity := b.draw_list_capacity[slot]
  offset := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(list) * int(capacity) * DRAW_COMMAND_SIZE)
  if !b.gctx.draw_indirect_count {
    vk.CmdDrawIndexedIndirect(cmd, buffer, offset, capacity, DRAW_COMMAND_SIZE)
    return
  }
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    buffer,
    offset,
    buffer,
    vk.DeviceSize(list * size_of(u32)),
    capacity,
    DRAW_COMMAND_SIZE,
  )
}

@(private)
draw_lists_copy_counts :: proc(b: ^Backend, cmd: vk.CommandBuffer, slot: u32, dst: ^Buffer) {
  barrier(cmd, .CULL_TO_COPY)
  region := vk.BufferCopy{size = DRAW_LIST_HEADER * size_of(u32)}
  vk.CmdCopyBuffer(cmd, b.draw_lists[slot].buffer, dst.buffer, 1, &region)
}
