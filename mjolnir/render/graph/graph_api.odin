package render_graph

import "../../gpu"
import vk "vendor:vulkan"

// ============================================================================
// Public Accessors
// ============================================================================

get_camera_handle :: proc(graph: ^Graph, instance_idx: int) -> u32 {
  if instance_idx < len(graph.camera_handles) {
    return graph.camera_handles[instance_idx]
  }
  return 0
}

get_light_handle :: proc(graph: ^Graph, instance_idx: int) -> u32 {
  if instance_idx < len(graph.light_handles) {
    return graph.light_handles[instance_idx]
  }
  return 0
}

get_light_handles :: proc(graph: ^Graph) -> []u32 {
  return graph.light_handles
}

camera_handle_count :: proc(graph: ^Graph) -> int {
  return len(graph.camera_handles)
}

light_handle_count :: proc(graph: ^Graph) -> int {
  return len(graph.light_handles)
}

pass_count :: proc(graph: ^Graph) -> int {
  return len(graph.sorted_passes)
}

// get_texture_handle returns the bindless handle bits for a named texture at the given frame.
// Returns (handle_bits, true) on success; (0, false) if not found or not a texture.
get_texture_handle :: proc(graph: ^Graph, name: string, frame_index: u32) -> (u64, bool) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return 0, false
  res := get_resource(graph, res_id)
  if len(res.texture_handle_bits) == 0 do return 0, false
  variant_idx := int(frame_index) % len(res.texture_handle_bits)
  return res.texture_handle_bits[variant_idx], true
}

// ============================================================================
// External Resource Update API
// ============================================================================

// Update the VkImage handle for an external texture registered with the graph.
// Call this each frame (before run_graph) when the handle changes — e.g. for
// the swapchain image. Once set, the graph will emit correct image barriers.
update_external_texture :: proc(
  graph: ^Graph,
  name: string,
  image: vk.Image,
  view: vk.ImageView,
) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return
  res := get_resource(graph, res_id)
  res.external_image = image
  res.external_image_view = view
}

// Update the VkBuffer handle for an external buffer registered with the graph.
// Call this each frame (before run_graph) when the handle changes.
update_external_buffer :: proc(
  graph: ^Graph,
  name: string,
  buffer: vk.Buffer,
) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return
  res := get_resource(graph, res_id)
  res.external_buffer = buffer
}

// ============================================================================
// Public API - Main Entry Points
// ============================================================================

// This file provides a clean public API for the frame graph system.
// Users should primarily use these functions.

// Compile (or recompile) a frame graph from pass declarations.
// gctx and tm are used for GPU resource allocation only — they are never stored.
// If the graph already contains compiled data it is destroyed first.
build_graph :: proc(
  graph: ^Graph,
  pass_decls: []PassDecl,
  ctx: CompileContext,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
  loc := #caller_location,
) -> CompileError {
  if graph.sorted_passes != nil {
    destroy(graph, gctx, tm)
  }

  new_graph, err := compile(pass_decls, ctx, loc)
  if err != .NONE {
    return err
  }
  graph^ = new_graph

  err = allocate_resources(graph, gctx, tm, loc)
  if err != .NONE {
    destroy(graph, gctx, tm)
    return err
  }

  compute_barriers(graph)

  return .NONE
}

// Create a pass iterator for executing the compiled graph frame-by-frame.
// The caller drives the loop: call next_pass to advance, pass_done after each pass.
//
// graphics_cmd: command buffer for GRAPHICS passes.
// compute_cmd:  command buffer for COMPUTE passes.
// Pass the same buffer for both when async compute is not in use.
make_pass_iterator :: proc(
  graph: ^Graph,
  frame_index: u32,
  graphics_cmd: vk.CommandBuffer,
  compute_cmd: vk.CommandBuffer,
) -> GraphPassIterator {
  return GraphPassIterator {
    _graph = graph,
    _frame_index = frame_index,
    _graphics_cmd = graphics_cmd,
    _compute_cmd = compute_cmd,
    _pass_idx = 0,
  }
}
