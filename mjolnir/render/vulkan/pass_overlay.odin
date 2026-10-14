package vulkan_backend

import "core:math/linalg"
import vk "vendor:vulkan"

// Vertex2D is one vertex of the 2D overlay.
Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
}

// UIBatch is a run of overlay indices drawn with one texture inside one scissor (x, y, w, h).
UIBatch :: struct {
  first_index: u32,
  index_count: u32,
  scissor:     [4]i32,
  texture:     TextureHandle,
}

// UI_MAX_VERTICES and UI_MAX_INDICES are the overlay's capacity per frame.
UI_MAX_VERTICES :: 65536
UI_MAX_INDICES :: 98304

@(private = "file")
VERTEX2D_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {binding = 0, location = 0, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, pos))},
  {binding = 0, location = 1, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, uv))},
  {binding = 0, location = 2, format = .R8G8B8A8_UNORM, offset = u32(offset_of(Vertex2D, color))},
}

@(private = "file")
OverlayPushConstants :: struct {
  projection: matrix[4, 4]f32,
  texture:    TextureHandle,
}

// The overlay draws render's 2D batches (FrameDesc.ui_*) into the swapchain image after
// post-processing, with one pipeline and one vertex stream.
@(private)
overlay_init :: proc(b: ^Backend) -> vk.Result {
  bindings := [?]vk.VertexInputBindingDescription{{binding = 0, stride = size_of(Vertex2D), inputRate = .VERTEX}}
  color_formats := [?]vk.Format{b.swapchain.format.format}
  blend := [?]vk.PipelineColorBlendAttachmentState{BLEND_ALPHA}
  b.pipelines[.OVERLAY] = create_graphics_pipeline(
    &b.gctx,
    {
      vert = #load("shader/ui/vert.spv"),
      frag = #load("shader/ui/frag.spv"),
      vertex_bindings = bindings[:],
      vertex_attributes = VERTEX2D_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      blend = blend[:],
      color_formats = color_formats[:],
      layout = b.scene.layout,
    },
  ) or_return
  for i in 0 ..< FRAMES_IN_FLIGHT {
    b.ui_vertex_buffers[i] = buffer_create(&b.gctx, UI_MAX_VERTICES * size_of(Vertex2D), {.VERTEX_BUFFER}) or_return
    b.ui_index_buffers[i] = buffer_create(&b.gctx, UI_MAX_INDICES * size_of(u32), {.INDEX_BUFFER}) or_return
  }
  return .SUCCESS
}

@(private)
overlay_record :: proc(
  b: ^Backend,
  desc: ^FrameDesc,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
  frame_index: u32,
) {
  if len(desc.ui_batches) == 0 do return
  begin_rendering(
    command_buffer,
    extent,
    nil,
    create_color_attachment(color_view, .LOAD, .STORE),
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, b.pipelines[.OVERLAY])
  // pixel y grows down, as clip-space y does
  push := OverlayPushConstants {
    projection = linalg.matrix_ortho3d_f32(0, f32(extent.width), 0, f32(extent.height), -1, 1),
  }
  bind_vertex_index_buffers(
    command_buffer,
    b.ui_vertex_buffers[frame_index].buffer,
    b.ui_index_buffers[frame_index].buffer,
  )
  for &batch in desc.ui_batches {
    if batch.index_count == 0 do continue
    s := batch.scissor
    scissor := vk.Rect2D{offset = {s.x, s.y}, extent = {u32(s.z), u32(s.w)}}
    vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
    push.texture = batch.texture
    push_constants(b, command_buffer, &push)
    vk.CmdDrawIndexed(command_buffer, batch.index_count, 1, batch.first_index, 0, 0)
  }
  vk.CmdEndRendering(command_buffer)
}
