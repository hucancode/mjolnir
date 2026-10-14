#+private
package render

import "gpu"
import vk "vendor:vulkan"

MAX_DEPTH_MIPS_LEVEL :: 16
// Mip 0 texels a depth pyramid group reduces per side (depth_reduce.comp).
@(private = "file")
PYRAMID_TILE :: 32

// Camera c's pyramid of frame f takes pyramid slot camera_slot(c) + f, which owns
// counter `slot`, Renderer.pyramids[slot] and storage images [slot * MAX_DEPTH_MIPS_LEVEL,
// (slot + 1) * MAX_DEPTH_MIPS_LEVEL) (Renderer.pyramid_views[slot]).
// Its draw lists take the same slot after CAMERA_DRAW_SLOT_BASE.
MAX_PYRAMID_SLOTS :: MAX_ACTIVE_CAMERAS * gpu.FRAMES_IN_FLIGHT

camera_slot :: #force_inline proc "contextless" (camera: u32) -> u32 {
  return camera * gpu.FRAMES_IN_FLIGHT
}

// A camera or a shadow map face. A drawn node goes to list type * list_stride of
// `draw_list`: cameras keep one list per material type (stride 1); shadow views share one
// list (stride 0) and tell draws apart by instance_tag.
ViewGPU :: struct {
  view:                matrix[4, 4]f32,
  projection:          matrix[4, 4]f32,
  view_projection:     matrix[4, 4]f32,
  // rebuilds world positions from depth
  inv_view_projection: matrix[4, 4]f32,
  planes:              [6][4]f32, // normalized, pointing inward
  position:            [4]f32,
  extent:              [2]f32,
  near, far:           f32,
  attachments:         [AttachmentType]u32,
  // bindless depth pyramid
  pyramid:         u32,
  // bit t: material type t is tested against the pyramid
  occlusion_mask:  u32,
  list_stride:     u32,
  // bit t: material type t is drawn
  type_mask:       u32,
  require_flags:   NodeFlagSet,
  // OR-ed into each draw's first_instance above the node index
  instance_tag:    u32,
  // render target layer
  layer:           u32,
  // bindless draw lists slot the view appends to
  draw_list:       u32,
  // draws per list
  list_capacity:   u32,
  _:               u32,
}
#assert(size_of(ViewGPU) == 448)

CAMERA_VIEW_BASE :: 0
SHADOW_VIEW_BASE :: MAX_ACTIVE_CAMERAS
MAX_VIEWS :: MAX_ACTIVE_CAMERAS + MAX_SHADOW_VIEWS

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

occlusion_init :: proc(r: ^Renderer) -> vk.Result {
  layout := r.scene.layout
  r.pipelines[.CULL] = gpu.create_compute_pipeline(&r.gctx, #load("shader/occlusion_culling/cull.spv"), layout) or_return
  r.pipelines[.DEPTH_REDUCE] = gpu.create_compute_pipeline(&r.gctx, #load("shader/occlusion_culling/depth_reduce.spv"), layout) or_return
  return .SUCCESS
}

// A depth pyramid is a max-depth texture at half the camera's resolution, with a storage view
// per mip. The views enter the storage image array at the next flush of the pyramid's frame
// (occlusion_bind_pyramid), once no frame in flight reads the slot's previous views.
occlusion_setup_pyramid :: proc(r: ^Renderer, slot: u32, extent: vk.Extent2D) -> vk.Result {
  gctx := &r.gctx
  extent := vk.Extent2D{max(1, extent.width / 2), max(1, extent.height / 2)}
  r.pyramids[slot] = allocate_texture(
    r,
    extent,
    .R32_SFLOAT,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    gpu.calculate_mip_levels(extent.width, extent.height),
    shared = true,
  ) or_return
  r.pyramid_bound[slot] = false
  img := texture_image(r, r.pyramids[slot])
  assert(img.mip_levels <= MAX_DEPTH_MIPS_LEVEL)
  gpu.queue_image_init(gctx, {img.image, {.COLOR}, {.SHADER_READ, .SHADER_WRITE}, {.COMPUTE_SHADER}})
  for mip in 0 ..< img.mip_levels {
    r.pyramid_views[slot][mip] = gpu.image_create_view(gctx.device, img, .D2, base_mip = mip) or_return
  }
  return .SUCCESS
}

// Call when no frame in flight reads the slot.
occlusion_bind_pyramid :: proc(r: ^Renderer, slot: u32) {
  if r.pyramid_bound[slot] do return
  r.pyramid_bound[slot] = true
  for view, mip in r.pyramid_views[slot] {
    if view == 0 do break
    gpu.write_descriptor(
      &r.gctx,
      r.scene.bindless_set,
      BINDING_STORAGE_IMAGES,
      slot * MAX_DEPTH_MIPS_LEVEL + u32(mip),
      .STORAGE_IMAGE,
      vk.DescriptorImageInfo{imageView = view, imageLayout = .GENERAL},
    )
  }
}

occlusion_destroy_pyramid :: proc(r: ^Renderer, slot: u32) {
  for view in r.pyramid_views[slot] do if view != 0 do gpu.defer_destroy(&r.gctx, view)
  destroy_texture(r, r.pyramids[slot])
  r.pyramid_views[slot] = {}
  r.pyramids[slot] = 0
  r.pyramid_bound[slot] = false
}

// The caller binds the reduce pipeline and orders the dispatch before the cull.
occlusion_build_pyramid :: proc(r: ^Renderer, cmd: vk.CommandBuffer, slot: u32, depth_index: u32) {
  img := texture_image(r, r.pyramids[slot])
  if img == nil || !r.pyramid_bound[slot] do return
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
  push_constants(r, cmd, &push)
  vk.CmdDispatch(cmd, groups.x, groups.y, 1)
}

// The caller zeroes the counts first (draw_lists_clear) and orders the clear before this.
occlusion_cull :: proc(r: ^Renderer, cmd: vk.CommandBuffer, first_view, view_count: u32) {
  if r.node_count == 0 || view_count == 0 do return
  vk.CmdBindPipeline(cmd, .COMPUTE, r.pipelines[.CULL])
  push := CullPushConstants {
    node_count = r.node_count,
    first_view = first_view,
  }
  push_constants(r, cmd, &push)
  vk.CmdDispatch(cmd, (r.node_count + 63) / 64, view_count, 1)
}

// counts at the head of a buffer, one per list; commands follow
DRAW_LIST_HEADER :: 8
#assert(len(MaterialType) <= DRAW_LIST_HEADER)
DRAW_COMMAND_SIZE :: size_of(vk.DrawIndexedIndirectCommand)

// camera slot c takes c * FRAMES_IN_FLIGHT + frame; shadow lists take the slots after every camera's
CAMERA_DRAW_SLOT_BASE :: 0
SHADOW_DRAW_SLOT_BASE :: MAX_ACTIVE_CAMERAS * gpu.FRAMES_IN_FLIGHT
MAX_DRAW_LIST_SLOTS :: SHADOW_DRAW_SLOT_BASE + gpu.FRAMES_IN_FLIGHT
// draws per list: a camera keeps one list per material type, the shadow views share one
CAMERA_LIST_CAPACITY :: MAX_NODES_IN_SCENE
SHADOW_LIST_CAPACITY :: SHADOW_MAX_DRAWS

// Draw lists are indirect draw lists in Renderer.draw_lists[slot], one device-local buffer per
// bindless draw-list slot holding up to DRAW_LIST_HEADER lists of `capacity` draws; list i has its
// count at u32 i. A slot's lists hold garbage until its first cull. Without drawIndirectCount
// every command is drawn, so a clear also zeroes the commands (instanceCount 0 draws nothing).

// Creates the FRAMES_IN_FLIGHT slots from first_slot.
draw_lists_create :: proc(r: ^Renderer, first_slot: u32, lists: u32, capacity: u32) -> vk.Result {
  size := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(lists) * int(capacity) * DRAW_COMMAND_SIZE)
  for slot in first_slot ..< first_slot + gpu.FRAMES_IN_FLIGHT {
    buffer := &r.draw_lists[slot]
    buffer^ = gpu.buffer_create(&r.gctx, size, {.STORAGE_BUFFER, .INDIRECT_BUFFER}, host_visible = false) or_return
    gpu.write_descriptor(&r.gctx, r.scene.bindless_set, BINDING_DRAW_LISTS, slot, .STORAGE_BUFFER, gpu.buffer_info(buffer))
  }
  return .SUCCESS
}

draw_lists_destroy :: proc(r: ^Renderer, first_slot: u32) {
  for &buffer in r.draw_lists[first_slot:][:gpu.FRAMES_IN_FLIGHT] {
    if buffer.buffer != 0 do gpu.defer_destroy(&r.gctx, buffer)
    buffer = {}
  }
}

// Order earlier indirect reads before it and the cull after it.
draw_lists_clear :: proc(r: ^Renderer, cmd: vk.CommandBuffer, slot: u32) {
  size := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32)) if r.gctx.draw_indirect_count else vk.DeviceSize(vk.WHOLE_SIZE)
  vk.CmdFillBuffer(cmd, r.draw_lists[slot].buffer, 0, size, 0)
}

// Call inside a render scope.
draw_lists_draw :: proc(r: ^Renderer, cmd: vk.CommandBuffer, slot: u32, list: u32, capacity: u32) {
  buffer := r.draw_lists[slot].buffer
  offset := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(list) * int(capacity) * DRAW_COMMAND_SIZE)
  if !r.gctx.draw_indirect_count {
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

draw_lists_copy_counts :: proc(r: ^Renderer, cmd: vk.CommandBuffer, slot: u32, dst: ^gpu.Buffer) {
  barrier(cmd, .CULL_TO_COPY)
  region := vk.BufferCopy{size = DRAW_LIST_HEADER * size_of(u32)}
  vk.CmdCopyBuffer(cmd, r.draw_lists[slot].buffer, dst.buffer, 1, &region)
}
