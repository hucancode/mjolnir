package vulkan_backend

import rhi "../rhi"

import vk "vendor:vulkan"


@(private = "file")
SHADOW_DEPTH_VERT :: #load("shader/shadow/vert.spv")
@(private = "file")
SHADOW_MAP_FORMAT :: vk.Format.D32_SFLOAT
@(private = "file")
SHADOW_SLOPE_BIAS :: 1.5

// One cull dispatch tests every node against every shadow view and appends the visible
// casters to one draw list; one layered draw renders every view into its atlas layer.
// Draw tags: first_instance = node | view << 16.
#assert(rhi.MAX_NODES_IN_SCENE <= 1 << 16)
#assert(rhi.MAX_VIEWS < 1 << 16)

@(private)
shadow_atlas_create :: proc(gctx: ^GPUContext, layers: u32) -> (Image, vk.Result) {
  return image_create(
    gctx,
    {rhi.SHADOW_MAP_SIZE, rhi.SHADOW_MAP_SIZE},
    SHADOW_MAP_FORMAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    layers = layers,
    array = true,
  )
}

// Doubles up to MAX_SHADOW_VIEWS and rebinds. Call once the frame's previous submission is done.
@(private)
shadow_atlas_reserve :: proc(b: ^Backend, frame_index: u32, layers: u32) -> vk.Result {
  atlas := &b.shadow_atlas[frame_index]
  if layers <= atlas.layers do return .SUCCESS
  grown := shadow_atlas_create(&b.gctx, max(layers, min(atlas.layers * 2, rhi.MAX_SHADOW_VIEWS))) or_return
  image_destroy(b.gctx.device, atlas)
  atlas^ = grown
  scene_write_binding(b, .SHADOW_MAPS, int(frame_index))
  return .SUCCESS
}

@(private)
shadow_init :: proc(b: ^Backend) -> vk.Result {
  b.pipelines[.SHADOW_DEPTH] = create_graphics_pipeline(
    &b.gctx,
    {
      vert = SHADOW_DEPTH_VERT,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:1],
      topology = .TRIANGLE_LIST,
      cull_mode = {.BACK},
      depth_clamp = b.gctx.depth_clamp,
      depth_bias = {0, SHADOW_SLOPE_BIAS},
      depth = READ_WRITE_DEPTH_STATE,
      depth_format = SHADOW_MAP_FORMAT,
      layout = b.scene.layout,
    },
  ) or_return
  return .SUCCESS
}

@(private)
shadow_record :: proc(b: ^Backend, desc: ^rhi.FrameDesc, frame_index: u32) {
  cmd := b.command_buffers[frame_index]
  atlas := &b.shadow_atlas[frame_index]
  // lighting binds the whole atlas, so every layer leaves UNDEFINED even when nothing renders
  image_discard_barrier(cmd, attachment_discard(atlas))
  view_count := desc.shadow_view_count
  if view_count == 0 do return
  barrier(cmd, .INDIRECT_TO_FILL)
  draw_lists_clear(b, cmd, desc.shadow_draw_list)
  barrier(cmd, .FILL_TO_CULL)
  occlusion_cull(b, cmd, desc.node_count, rhi.SHADOW_VIEW_BASE, view_count)
  barrier(cmd, .CULL_TO_INDIRECT)
  extent := vk.Extent2D{rhi.SHADOW_MAP_SIZE, rhi.SHADOW_MAP_SIZE}
  begin_rendering(cmd, extent, create_depth_attachment(atlas.view), layer_count = view_count)
  vk.CmdBindPipeline(cmd, .GRAPHICS, b.pipelines[.SHADOW_DEPTH])
  bind_mesh_buffers(b, cmd)
  draw_lists_draw(b, cmd, desc.shadow_draw_list, 0)
  vk.CmdEndRendering(cmd)
  barrier(cmd, .SHADOW_TO_LIGHTING)
}
