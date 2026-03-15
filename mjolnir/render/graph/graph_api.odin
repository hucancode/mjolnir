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

is_compiled :: proc(graph: ^Graph) -> bool {
  return graph.sorted_passes != nil
}

// get_texture_handle returns the bindless handle bits for a named texture at the given frame.
// Returns (handle_bits, true) on success; (0, false) if not found or not a texture.
get_texture_handle :: proc(graph: ^Graph, name: string, frame_index: u32) -> (u64, bool) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return 0, false
  res := get_resource(graph, res_id)

  switch d in res.data {
  case ResourceTexture:
    if len(d.texture_handle_bits) == 0 do return 0, false
    return d.texture_handle_bits[int(frame_index) % len(d.texture_handle_bits)], true
  case ResourceTextureCube:
    if len(d.texture_handle_bits) == 0 do return 0, false
    return d.texture_handle_bits[int(frame_index) % len(d.texture_handle_bits)], true
  case ResourceBuffer:
    return 0, false
  }
  return 0, false
}

// ============================================================================
// External Resource Update API
// ============================================================================

update_external_texture :: proc(
  graph: ^Graph,
  name: string,
  image: vk.Image,
  view: vk.ImageView,
) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return
  res := get_resource(graph, res_id)
  switch &d in res.data {
  case ResourceTexture:
    d.external_image = image
    d.external_image_view = view
  case ResourceTextureCube:
    d.external_image = image
    d.external_image_view = view
  case ResourceBuffer:
  }
}

update_external_buffer :: proc(
  graph: ^Graph,
  name: string,
  buffer: vk.Buffer,
) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return
  res := get_resource(graph, res_id)
  switch &d in res.data {
  case ResourceBuffer:
    d.external = buffer
  case ResourceTexture, ResourceTextureCube:
  }
}

// ============================================================================
// Public API - Main Entry Points
// ============================================================================

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

make_pass_iterator :: proc(
  graph: ^Graph,
  frame_index: u32,
  graphics_cmd: vk.CommandBuffer,
  compute_cmd: vk.CommandBuffer,
) -> GraphPassIterator {
  return GraphPassIterator {
    _graph        = graph,
    _frame_index  = frame_index,
    _graphics_cmd = graphics_cmd,
    _compute_cmd  = compute_cmd,
    _pass_idx     = 0,
  }
}
