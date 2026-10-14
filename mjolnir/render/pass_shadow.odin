#+private
package render

import "gpu"
import vk "vendor:vulkan"

@(private = "file")
SHADOW_DEPTH_VERT :: #load("shader/shadow/vert.spv")
@(private = "file")
SHADOW_MAP_FORMAT :: vk.Format.D32_SFLOAT
@(private = "file")
SHADOW_SLOPE_BIAS :: 1.5

// the material type must also be in GBUFFER_TYPES
SHADOW_CASTER_FLAGS :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}

// One cull dispatch tests every node against every shadow view and appends the visible
// casters to one draw list; one layered draw renders every view into its atlas layer.
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

// Doubles up to MAX_SHADOW_VIEWS and rebinds. Call once the frame's previous submission is done.
shadow_atlas_reserve :: proc(r: ^Renderer, frame_index: u32, layers: u32) -> vk.Result {
  atlas := &r.shadow_atlas[frame_index]
  if layers <= atlas.layers do return .SUCCESS
  grown := shadow_atlas_create(&r.gctx, max(layers, min(atlas.layers * 2, MAX_SHADOW_VIEWS))) or_return
  gpu.image_destroy(r.gctx.device, atlas)
  atlas^ = grown
  scene_write_binding(r, .SHADOW_MAPS, int(frame_index))
  return .SUCCESS
}

shadow_init :: proc(r: ^Renderer) -> vk.Result {
  draw_lists_create(r, SHADOW_DRAW_SLOT_BASE, 1, SHADOW_LIST_CAPACITY) or_return
  r.pipelines[.SHADOW_DEPTH] = gpu.create_graphics_pipeline(
    &r.gctx,
    {
      vert = SHADOW_DEPTH_VERT,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:1],
      topology = .TRIANGLE_LIST,
      cull_mode = {.BACK},
      depth_clamp = r.gctx.depth_clamp,
      depth_bias = {0, SHADOW_SLOPE_BIAS},
      depth = gpu.READ_WRITE_DEPTH_STATE,
      depth_format = SHADOW_MAP_FORMAT,
      layout = r.scene.layout,
    },
  ) or_return
  return .SUCCESS
}

shadow_record :: proc(r: ^Renderer, frame_index: u32) {
  cmd := r.command_buffers[frame_index]
  atlas := &r.shadow_atlas[frame_index]
  // lighting binds the whole atlas, so every layer leaves UNDEFINED even when nothing renders
  gpu.image_discard_barrier(cmd, gpu.attachment_discard(atlas))
  view_count := r.shadow_view_count
  if view_count == 0 do return
  barrier(cmd, .INDIRECT_TO_FILL)
  draw_lists_clear(r, cmd, SHADOW_DRAW_SLOT_BASE + frame_index)
  barrier(cmd, .FILL_TO_CULL)
  occlusion_cull(r, cmd, SHADOW_VIEW_BASE, view_count)
  barrier(cmd, .CULL_TO_INDIRECT)
  extent := vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
  gpu.begin_rendering(cmd, extent, gpu.create_depth_attachment(atlas.view), layer_count = view_count)
  vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipelines[.SHADOW_DEPTH])
  bind_mesh_buffers(r, cmd)
  draw_lists_draw(r, cmd, SHADOW_DRAW_SLOT_BASE + frame_index, 0, SHADOW_LIST_CAPACITY)
  vk.CmdEndRendering(cmd)
  barrier(cmd, .SHADOW_TO_LIGHTING)
}
