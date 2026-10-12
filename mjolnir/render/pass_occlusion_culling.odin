#+private
package render

import "gpu"
import vk "vendor:vulkan"

MAX_DEPTH_MIPS_LEVEL :: 16
// Mip 0 texels a depth pyramid group reduces per side (depth_reduce.comp).
@(private = "file")
PYRAMID_TILE :: 32

// Pyramid slots: camera slot c's pyramid of frame f takes slot
// c * FRAMES_IN_FLIGHT + f, which owns counter `slot` and storage images
// [slot * MAX_DEPTH_MIPS_LEVEL, (slot + 1) * MAX_DEPTH_MIPS_LEVEL).
MAX_PYRAMID_SLOTS :: MAX_ACTIVE_CAMERAS * gpu.FRAMES_IN_FLIGHT

// One view of the scene: a camera, or a face of a shadow map. Rendered
// shaders project with it; the cull shader tests nodes against it. A drawn
// node goes to list type * list_stride of draw lists `draw_list`: a camera
// keeps one list per material type (stride 1), the shadow views share one
// list for every type (stride 0) and tell their draws apart by instance_tag.
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
  // this frame's bindless images of a camera view
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

// View table layout: one view per camera slot, then the shadow views.
CAMERA_VIEW_BASE :: 0
SHADOW_VIEW_BASE :: MAX_ACTIVE_CAMERAS
MAX_VIEWS :: MAX_ACTIVE_CAMERAS + MAX_SHADOW_VIEWS

CullPushConstants :: struct {
  node_count: u32,
  first_view: u32,
}

DepthReducePushConstants :: struct {
  depth_index: u32,
  mip_count:   u32,
  group_count: u32,
  slot:        u32,
}

// Hierarchical max-depth buffer at half the camera's resolution, with a
// storage view per mip. The views enter the storage image array at the next
// flush of the pyramid's frame (occlusion_bind_pyramid), once no frame in
// flight still reads the slot's previous views.
DepthPyramid :: struct {
  texture: TextureHandle,
  views:   [MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
  slot:    u32,
  bound:   bool,
}

// Frustum + occlusion culling of nodes against views into the bindless draw
// lists, and the depth reduction that builds the pyramids it tests against.
occlusion_init :: proc(r: ^Renderer) -> vk.Result {
  layout := r.scene.layout
  r.pipelines[.CULL] = gpu.create_compute_pipeline(&r.gctx, #load("shader/occlusion_culling/cull.spv"), layout) or_return
  r.pipelines[.DEPTH_REDUCE] = gpu.create_compute_pipeline(&r.gctx, #load("shader/occlusion_culling/depth_reduce.spv"), layout) or_return
  return .SUCCESS
}

// Create the pyramid texture of pyramid slot `slot` for a camera of `extent`
// and its per-mip views.
occlusion_setup_pyramid :: proc(
  r: ^Renderer,
  pyramid: ^DepthPyramid,
  extent: vk.Extent2D,
  slot: u32,
) -> vk.Result {
  gctx := &r.gctx
  extent := vk.Extent2D{max(1, extent.width / 2), max(1, extent.height / 2)}
  pyramid.slot = slot
  pyramid.texture = allocate_texture(
    r,
    extent,
    .R32_SFLOAT,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    gpu.calculate_mip_levels(extent.width, extent.height),
    shared = true,
  ) or_return
  img := texture_image(r, pyramid.texture)
  assert(img.mip_levels <= MAX_DEPTH_MIPS_LEVEL)
  gpu.queue_image_init(gctx, {img.image, {.COLOR}, {.SHADER_READ, .SHADER_WRITE}, {.COMPUTE_SHADER}})
  for mip in 0 ..< img.mip_levels {
    pyramid.views[mip] = gpu.image_create_view(gctx.device, img, .D2, base_mip = mip) or_return
  }
  return .SUCCESS
}

// Write the pyramid's mip views into its storage image slots. Call when no
// frame in flight reads the slots: in the flush of the pyramid's frame.
occlusion_bind_pyramid :: proc(r: ^Renderer, pyramid: ^DepthPyramid) {
  if pyramid.bound do return
  pyramid.bound = true
  for view, mip in pyramid.views {
    if view == 0 do break
    gpu.write_descriptor(
      &r.gctx,
      r.scene.bindless_set,
      BINDING_STORAGE_IMAGES,
      pyramid.slot * MAX_DEPTH_MIPS_LEVEL + u32(mip),
      .STORAGE_IMAGE,
      vk.DescriptorImageInfo{imageView = view, imageLayout = .GENERAL},
    )
  }
}

occlusion_destroy_pyramid :: proc(r: ^Renderer, pyramid: ^DepthPyramid) {
  for view in pyramid.views do if view != 0 do gpu.defer_destroy(&r.gctx, view)
  destroy_texture(r, pyramid.texture)
  pyramid^ = {}
}

// Reduce depth image `depth_index` into every mip of `pyramid` in one
// dispatch. The caller binds the reduce pipeline and orders the dispatch
// before the cull.
occlusion_build_pyramid :: proc(
  r: ^Renderer,
  cmd: vk.CommandBuffer,
  pyramid: ^DepthPyramid,
  depth_index: u32,
) {
  img := texture_image(r, pyramid.texture)
  if img == nil || !pyramid.bound do return
  groups := [2]u32 {
    (img.extent.width + PYRAMID_TILE - 1) / PYRAMID_TILE,
    (img.extent.height + PYRAMID_TILE - 1) / PYRAMID_TILE,
  }
  push := DepthReducePushConstants {
    depth_index = depth_index,
    mip_count   = img.mip_levels,
    group_count = groups.x * groups.y,
    slot        = pyramid.slot,
  }
  push_constants(r, cmd, &push)
  vk.CmdDispatch(cmd, groups.x, groups.y, 1)
}

// Cull every node against views [first_view, first_view + view_count) into
// each view's draw lists: one dispatch of node groups by views. The caller
// zeroes the lists' counts first (draw_lists_clear) and orders the clear
// before this.
occlusion_cull :: proc(r: ^Renderer, cmd: vk.CommandBuffer, first_view, view_count: u32) {
  if u32(len(r.attachments)) == 0 || view_count == 0 do return
  vk.CmdBindPipeline(cmd, .COMPUTE, r.pipelines[.CULL])
  push := CullPushConstants {
    node_count = u32(len(r.attachments)),
    first_view = first_view,
  }
  push_constants(r, cmd, &push)
  vk.CmdDispatch(cmd, (u32(len(r.attachments)) + 63) / 64, view_count, 1)
}

// Counts at the head of a draw list buffer, one per list; commands follow.
DRAW_LIST_HEADER :: 8
#assert(len(MaterialType) <= DRAW_LIST_HEADER)
@(private)
DRAW_COMMAND_SIZE :: size_of(vk.DrawIndexedIndirectCommand)

// Bindless draw list slots: camera slot c takes c * FRAMES_IN_FLIGHT + frame,
// the shadow lists take the slots after every camera's.
@(private)
CAMERA_DRAW_SLOT_BASE :: 0
@(private)
SHADOW_DRAW_SLOT_BASE :: MAX_ACTIVE_CAMERAS * gpu.FRAMES_IN_FLIGHT
@(private)
MAX_DRAW_LIST_SLOTS :: SHADOW_DRAW_SLOT_BASE + gpu.FRAMES_IN_FLIGHT

// Per-frame indirect draw lists: one device-local buffer per frame in flight
// holding up to DRAW_LIST_HEADER lists, each `capacity` draws. A cull pass
// writes them through the bindless draw list array (slot `slot + frame`), and
// vkCmdDrawIndexedIndirectCount consumes them straight from the buffer: list
// i has its count at u32 i and its commands from DRAW_LIST_HEADER u32s plus
// i * capacity commands. A frame's lists hold garbage until its first cull.
DrawLists :: struct {
  buffers:  [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  slot:     u32,
  capacity: u32, // draws per list
}

draw_lists_init :: proc(
  self: ^DrawLists,
  r: ^Renderer,
  slot: u32,
  lists: u32,
  capacity: u32,
) -> vk.Result {
  self.slot = slot
  self.capacity = capacity
  size := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(lists) * int(capacity) * DRAW_COMMAND_SIZE)
  for &buffer, frame in self.buffers {
    buffer = gpu.buffer_create(&r.gctx, size, {.STORAGE_BUFFER, .INDIRECT_BUFFER}, host_visible = false) or_return
    gpu.write_descriptor(
      &r.gctx,
      r.scene.bindless_set,
      BINDING_DRAW_LISTS,
      slot + u32(frame),
      .STORAGE_BUFFER,
      gpu.buffer_info(&buffer),
    )
  }
  return .SUCCESS
}

// Queue the buffers for destruction once no frame in flight reads them.
draw_lists_destroy :: proc(self: ^DrawLists, gctx: ^gpu.GPUContext) {
  for buffer in self.buffers do if buffer.buffer != 0 do gpu.defer_destroy(gctx, buffer)
  self^ = {}
}

// Zero frame `frame_index`'s counts so the cull can append. Order earlier
// indirect reads of the lists before it and the cull after it.
draw_lists_clear :: proc(self: ^DrawLists, cmd: vk.CommandBuffer, frame_index: u32) {
  vk.CmdFillBuffer(cmd, self.buffers[frame_index].buffer, 0, DRAW_LIST_HEADER * size_of(u32), 0)
}

// Draw list `list` of frame `frame_index`. Call inside a render scope.
draw_lists_draw :: proc(self: ^DrawLists, cmd: vk.CommandBuffer, frame_index: u32, list: u32) {
  buffer := self.buffers[frame_index].buffer
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    buffer,
    vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(list) * int(self.capacity) * DRAW_COMMAND_SIZE),
    buffer,
    vk.DeviceSize(list * size_of(u32)),
    self.capacity,
    DRAW_COMMAND_SIZE,
  )
}

// Copy frame `frame_index`'s counts into `dst` once the draws that read
// them are recorded.
draw_lists_copy_counts :: proc(self: ^DrawLists, cmd: vk.CommandBuffer, frame_index: u32, dst: ^gpu.Buffer) {
  gpu.memory_barrier(cmd, {.SHADER_WRITE}, {.TRANSFER_READ}, {.COMPUTE_SHADER, .DRAW_INDIRECT}, {.TRANSFER})
  region := vk.BufferCopy{size = DRAW_LIST_HEADER * size_of(u32)}
  vk.CmdCopyBuffer(cmd, self.buffers[frame_index].buffer, dst.buffer, 1, &region)
}

// Make the draw lists written by cull compute passes readable as indirect
// args.
@(private)
indirect_barrier :: proc(cmd: vk.CommandBuffer) {
  gpu.memory_barrier(cmd, {.SHADER_WRITE}, {.INDIRECT_COMMAND_READ}, {.COMPUTE_SHADER}, {.DRAW_INDIRECT})
}
