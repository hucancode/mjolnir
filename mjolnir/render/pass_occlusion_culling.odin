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

// Frustum + occlusion culling of nodes against views into the bindless draw
// lists, and the depth reduction that builds the pyramids it tests against.
// Both run on the scene layout.
OcclusionSystem :: struct {
  cull_pipeline:   vk.Pipeline,
  reduce_pipeline: vk.Pipeline,
  // one per pyramid slot: groups done this dispatch; the last one resets it
  counters:        gpu.Buffer,
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

occlusion_init :: proc(r: ^Manager) -> (ret: vk.Result) {
  self := &r.internal.visibility
  gctx := &r.gctx
  defer if ret != .SUCCESS do occlusion_shutdown(self, gctx)
  layout := r.internal.scene.layout
  self.cull_pipeline = gpu.create_compute_pipeline(gctx, #load("shader/occlusion_culling/cull.spv"), layout) or_return
  self.reduce_pipeline = gpu.create_compute_pipeline(
    gctx,
    #load("shader/occlusion_culling/depth_reduce.spv"),
    layout,
  ) or_return
  self.counters = gpu.buffer_create(
    gctx,
    MAX_PYRAMID_SLOTS * size_of(u32),
    {.STORAGE_BUFFER},
    host_visible = false,
  ) or_return
  gpu.queue_buffer_fill(gctx, &self.counters)
  gpu.write_descriptor(
    gctx,
    r.texture_manager.descriptor_set,
    BINDING_PYRAMID_COUNTERS,
    0,
    .STORAGE_BUFFER,
    gpu.buffer_info(&self.counters),
  )
  return .SUCCESS
}

occlusion_shutdown :: proc(self: ^OcclusionSystem, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.reduce_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  gpu.buffer_destroy(gctx.device, &self.counters)
  self^ = {}
}

// Create the pyramid texture of pyramid slot `slot` for a camera of `extent`
// and its per-mip views.
occlusion_setup_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  pyramid: ^DepthPyramid,
  texture_manager: ^TextureManager,
  extent: vk.Extent2D,
  slot: u32,
) -> vk.Result {
  extent := vk.Extent2D{max(1, extent.width / 2), max(1, extent.height / 2)}
  pyramid.slot = slot
  pyramid.texture = allocate_texture(
    texture_manager,
    gctx,
    extent,
    .R32_SFLOAT,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    gpu.calculate_mip_levels(extent.width, extent.height),
    shared = true,
  ) or_return
  img := get_texture(texture_manager, pyramid.texture)
  assert(img.mip_levels <= MAX_DEPTH_MIPS_LEVEL)
  gpu.queue_image_init(gctx, {img.image, {.COLOR}, {.SHADER_READ, .SHADER_WRITE}, {.COMPUTE_SHADER}})
  for mip in 0 ..< img.mip_levels {
    pyramid.views[mip] = gpu.image_create_view(gctx.device, img, .D2, base_mip = mip) or_return
  }
  return .SUCCESS
}

// Write the pyramid's mip views into its storage image slots. Call when no
// frame in flight reads the slots: in the flush of the pyramid's frame.
occlusion_bind_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  pyramid: ^DepthPyramid,
  texture_manager: ^TextureManager,
) {
  if pyramid.bound do return
  pyramid.bound = true
  for view, mip in pyramid.views {
    if view == 0 do break
    gpu.write_descriptor(
      gctx,
      texture_manager.descriptor_set,
      BINDING_STORAGE_IMAGES,
      pyramid.slot * MAX_DEPTH_MIPS_LEVEL + u32(mip),
      .STORAGE_IMAGE,
      vk.DescriptorImageInfo{imageView = view, imageLayout = .GENERAL},
    )
  }
}

occlusion_destroy_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  pyramid: ^DepthPyramid,
  texture_manager: ^TextureManager,
) {
  for view in pyramid.views do if view != 0 do gpu.defer_destroy(gctx, view)
  if pyramid.texture != {} do free_texture(texture_manager, gctx, pyramid.texture)
  pyramid^ = {}
}

// Reduce depth image `depth_index` into every mip of `pyramid` in one
// dispatch. The caller binds the reduce pipeline and orders the dispatch
// before the cull.
occlusion_build_pyramid :: proc(
  r: ^Manager,
  cmd: vk.CommandBuffer,
  pyramid: ^DepthPyramid,
  depth_index: u32,
) {
  img := get_texture(&r.texture_manager, pyramid.texture)
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
occlusion_cull :: proc(r: ^Manager, cmd: vk.CommandBuffer, first_view, view_count: u32) {
  if r.node_count == 0 || view_count == 0 do return
  vk.CmdBindPipeline(cmd, .COMPUTE, r.internal.visibility.cull_pipeline)
  push := CullPushConstants {
    node_count = r.node_count,
    first_view = first_view,
  }
  push_constants(r, cmd, &push)
  vk.CmdDispatch(cmd, (r.node_count + 63) / 64, view_count, 1)
}
