#+private
package render

import geom "../geometry"
import "gpu"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADOW_DEPTH_VERT :: #load("shader/shadow/vert.spv")
SHADOW_MAP_FORMAT :: vk.Format.D32_SFLOAT

// Node flags of a shadow caster; its material type also needs
// MATERIAL_PIPELINES[type].shadow.
SHADOW_CASTER_FLAGS :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}

// One cull dispatch per frame tests every node against every shadow view
// (views from SHADOW_VIEW_BASE) and appends the visible casters to one draw
// list, each draw tagged with its view; one layered draw then renders every
// view into its atlas layer.
ShadowSystem :: struct {
  depth_pipeline: vk.Pipeline,
  draws:          DrawLists,
}

// One frame's shadow maps: a 2D depth array with one layer per shadow view.
// A map takes SHADOW_LAYERS[type] layers from its first layer.
ShadowAtlas :: struct {
  image:  gpu.Image, // view: the 2D array
  layers: u32,
}

// Draw tags: first_instance = node | view << 16.
#assert(MAX_NODES_IN_SCENE <= 1 << 16)
#assert(MAX_VIEWS < 1 << 16)

shadow_atlas_init :: proc(atlas: ^ShadowAtlas, gctx: ^gpu.GPUContext, layers: u32) -> vk.Result {
  atlas.image = gpu.image_create(
    gctx,
    {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
    SHADOW_MAP_FORMAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    layers = layers,
    array = true,
  ) or_return
  atlas.layers = layers
  return .SUCCESS
}

shadow_atlas_destroy :: proc(atlas: ^ShadowAtlas, device: vk.Device) {
  gpu.image_destroy(device, &atlas.image)
  atlas^ = {}
}

// Grow frame `frame_index`'s atlas to hold `layers` layers, doubling up to
// MAX_SHADOW_VIEWS, and rebind it. Called by flush, after the
// frame's previous submission is done with it.
shadow_atlas_reserve :: proc(r: ^Manager, frame_index: u32, layers: u32) -> vk.Result {
  atlas := &r.internal.shadow_atlas[frame_index]
  if layers <= atlas.layers do return .SUCCESS
  grown: ShadowAtlas
  capacity := max(layers, min(atlas.layers * 2, MAX_SHADOW_VIEWS))
  shadow_atlas_init(&grown, &r.gctx, capacity) or_return
  shadow_atlas_destroy(atlas, r.gctx.device)
  atlas^ = grown
  scene_write_binding(r, .SHADOW_MAPS, int(frame_index))
  return .SUCCESS
}

shadow_safe_normalize :: proc(v: [3]f32, fallback: [3]f32) -> [3]f32 {
  len_sq := linalg.dot(v, v)
  if len_sq < 1e-6 do return fallback
  return linalg.normalize(v)
}

// View from `position` along the normalized `direction`.
shadow_make_light_view :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  up := [3]f32{0, 1, 0}
  if math.abs(linalg.dot(direction, up)) > 0.95 {
    up = {0, 0, 1}
  }
  return linalg.matrix4_look_at(position, position + direction, up)
}

// Square perspective projection of a spot light's cone or a point light's
// cube face, reaching `radius`.
shadow_projection_perspective :: proc(fovy, radius: f32) -> matrix[4, 4]f32 {
  near :: 0.1
  return geom.make_perspective_matrix(max(fovy, 0.001), 1.0, near, max(near + 0.1, radius))
}

// World size of a texel of shadow_projection_perspective(fovy, _) per unit of
// view depth.
shadow_texel_perspective :: proc(fovy: f32) -> f32 {
  return 2 * math.tan(0.5 * max(fovy, 0.001)) / SHADOW_MAP_SIZE
}

// Half extent of a directional light's shadow box.
shadow_radius_directional :: proc(shadow_radius: f32) -> f32 {
  return max(shadow_radius, 0.5)
}

// Orthographic shadow of the box of half extent `radius` centered on
// `position`, looking along the normalized `direction`.
shadow_matrices_directional :: proc(
  position, direction: [3]f32,
  radius: f32,
) -> (
  view, projection: matrix[4, 4]f32,
) {
  view = shadow_make_light_view(position - direction * radius, direction)
  projection = geom.make_ortho_matrix(-radius, radius, -radius, radius, 0, 2 * radius)
  return
}

shadow_init :: proc(r: ^Manager) -> (ret: vk.Result) {
  self := &r.internal.shadow
  gctx := &r.gctx
  defer if ret != .SUCCESS do shadow_shutdown(self, gctx)
  draw_lists_init(&self.draws, r, SHADOW_DRAW_SLOT_BASE, 1, SHADOW_MAX_DRAWS) or_return
  self.depth_pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = SHADOW_DEPTH_VERT,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = POSITION_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      raster = gpu.STANDARD_RASTERIZER,
      depth = gpu.READ_WRITE_DEPTH_STATE,
      depth_format = SHADOW_MAP_FORMAT,
      layout = r.internal.scene.layout,
    },
  ) or_return
  return .SUCCESS
}

shadow_shutdown :: proc(self: ^ShadowSystem, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  draw_lists_destroy(&self.draws, gctx)
  self^ = {}
}

// Render every shadow map of this frame: cull every node against every shadow
// view (written by upload_lights) in one dispatch, then draw the combined
// list into the atlas in one layered draw. The maps are packed from layer 0,
// so the views cover exactly the layers in use.
shadow_record :: proc(r: ^Manager, frame_index: u32) {
  self := &r.internal.shadow
  cmd := r.internal.command_buffers[frame_index]
  atlas := &r.internal.shadow_atlas[frame_index]
  // Every layer leaves UNDEFINED, including when nothing renders: lighting
  // binds the whole atlas.
  gpu.image_discard_barrier(cmd, gpu.attachment_discard(&atlas.image))
  view_count := r.internal.shadow_view_count
  if view_count == 0 do return
  // Earlier draws of this list finish before the clear, the clear before the
  // cull.
  gpu.memory_barrier(cmd, {}, {}, {.DRAW_INDIRECT}, {.TRANSFER})
  draw_lists_clear(&self.draws, cmd, frame_index)
  gpu.memory_barrier(cmd, {.TRANSFER_WRITE}, {.SHADER_READ, .SHADER_WRITE}, {.TRANSFER}, {.COMPUTE_SHADER})
  occlusion_cull(r, cmd, SHADOW_VIEW_BASE, view_count)
  indirect_barrier(cmd)
  extent := vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
  gpu.begin_rendering(cmd, extent, gpu.create_depth_attachment(atlas.image.view), layer_count = view_count)
  gpu.set_viewport_scissor(cmd, extent)
  vk.CmdBindPipeline(cmd, .GRAPHICS, self.depth_pipeline)
  bind_mesh_buffers(r, cmd)
  draw_lists_draw(&self.draws, cmd, frame_index, 0)
  vk.CmdEndRendering(cmd)
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
  )
}
