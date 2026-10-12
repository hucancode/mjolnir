#+private
package render

import "gpu"
import vk "vendor:vulkan"

SHADOW_DEPTH_VERT :: #load("shader/shadow/vert.spv")
SHADOW_MAP_FORMAT :: vk.Format.D32_SFLOAT

// Node flags of a shadow caster; its material type also needs
// MATERIAL_PIPELINES[type].shadow.
SHADOW_CASTER_FLAGS :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}

// One cull dispatch per frame tests every node against every shadow view
// (views from SHADOW_VIEW_BASE) and appends the visible casters to one draw
// list, each draw tagged with its view; one layered draw then renders every
// view into its atlas layer. A frame's shadow atlas is a 2D depth array with
// one layer per shadow view; a map takes len(SHADOW_FACES[type]) layers.

// Draw tags: first_instance = node | view << 16.
#assert(MAX_NODES_IN_SCENE <= 1 << 16)
#assert(MAX_VIEWS < 1 << 16)

shadow_atlas_create :: proc(gctx: ^gpu.GPUContext, layers: u32) -> (gpu.Image, vk.Result) {
  return gpu.image_create(
    gctx,
    {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
    SHADOW_MAP_FORMAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    layers = layers,
    array = true,
  )
}

// Grow frame `frame_index`'s atlas to hold `layers` layers, doubling up to
// MAX_SHADOW_VIEWS, and rebind it. Called by flush, after the
// frame's previous submission is done with it.
shadow_atlas_reserve :: proc(r: ^Manager, frame_index: u32, layers: u32) -> vk.Result {
  atlas := &r.shadow_atlas[frame_index]
  if layers <= atlas.layers do return .SUCCESS
  grown := shadow_atlas_create(&r.gctx, max(layers, min(atlas.layers * 2, MAX_SHADOW_VIEWS))) or_return
  gpu.image_destroy(r.gctx.device, atlas)
  atlas^ = grown
  scene_write_binding(r, .SHADOW_MAPS, int(frame_index))
  return .SUCCESS
}

shadow_init :: proc(r: ^Manager) -> vk.Result {
  draw_lists_init(&r.shadow_draws, r, SHADOW_DRAW_SLOT_BASE, 1, SHADOW_MAX_DRAWS) or_return
  r.pipelines[.SHADOW_DEPTH] = gpu.create_graphics_pipeline(
    &r.gctx,
    {
      vert = SHADOW_DEPTH_VERT,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:1],
      topology = .TRIANGLE_LIST,
      cull_mode = {.BACK},
      depth = gpu.READ_WRITE_DEPTH_STATE,
      depth_format = SHADOW_MAP_FORMAT,
      layout = r.scene.layout,
    },
  ) or_return
  return .SUCCESS
}

// Render every shadow map of this frame: cull every node against every shadow
// view (written by collect_lights) in one dispatch, then draw the combined
// list into the atlas in one layered draw. The maps are packed from layer 0,
// so the views cover exactly the layers in use.
shadow_record :: proc(r: ^Manager, frame_index: u32) {
  cmd := r.command_buffers[frame_index]
  atlas := &r.shadow_atlas[frame_index]
  // Every layer leaves UNDEFINED, including when nothing renders: lighting
  // binds the whole atlas.
  gpu.image_discard_barrier(cmd, gpu.attachment_discard(atlas))
  view_count := r.shadow_view_count
  if view_count == 0 do return
  // Earlier draws of this list finish before the clear, the clear before the
  // cull.
  gpu.memory_barrier(cmd, {}, {}, {.DRAW_INDIRECT}, {.TRANSFER})
  draw_lists_clear(&r.shadow_draws, cmd, frame_index)
  gpu.memory_barrier(cmd, {.TRANSFER_WRITE}, {.SHADER_READ, .SHADER_WRITE}, {.TRANSFER}, {.COMPUTE_SHADER})
  occlusion_cull(r, cmd, SHADOW_VIEW_BASE, view_count)
  indirect_barrier(cmd)
  extent := vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
  gpu.begin_rendering(cmd, extent, gpu.create_depth_attachment(atlas.view), layer_count = view_count)
  vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipelines[.SHADOW_DEPTH])
  bind_mesh_buffers(r, cmd)
  draw_lists_draw(&r.shadow_draws, cmd, frame_index, 0)
  vk.CmdEndRendering(cmd)
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
  )
}
