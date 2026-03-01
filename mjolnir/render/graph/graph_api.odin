package render_graph

import vk "vendor:vulkan"

// ============================================================================
// External Resource Update API
// ============================================================================

// Update the VkImage handle for an external texture registered with the graph.
// Call this each frame (before run_graph) when the handle changes — e.g. for
// the swapchain image. Once set, the graph will emit correct image barriers.
update_external_texture :: proc(graph: ^Graph, name: string, image: vk.Image, view: vk.ImageView) {
	res_id, found := find_resource_by_name(graph, name)
	if !found do return
	res := get_resource(graph, res_id)
	res.external_image      = image
	res.external_image_view = view
}

// Update the VkBuffer handle for an external buffer registered with the graph.
// Call this each frame (before run_graph) when the handle changes.
update_external_buffer :: proc(graph: ^Graph, name: string, buffer: vk.Buffer) {
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
// If the graph already contains compiled data it is destroyed first.
// tm_ptr: rawptr to ^gpu.TextureManager (borrowed for allocation only, not stored)
build_graph :: proc(
	graph: ^Graph,
	pass_decls: []PassDecl,
	ctx: CompileContext,
	tm_ptr: rawptr,
	loc := #caller_location,
) -> CompileError {
	if graph.sorted_passes != nil {
		destroy(graph, ctx.gctx, tm_ptr)
	}

	new_graph, err := compile(pass_decls, ctx, loc)
	if err != .NONE {
		return err
	}
	graph^ = new_graph

	err = allocate_resources(graph, ctx.gctx, tm_ptr, loc)
	if err != .NONE {
		destroy(graph, ctx.gctx, tm_ptr)
		return err
	}

	compute_barriers(graph)

	return .NONE
}

// Execute compiled graph for a frame.
// graphics_cmd: command buffer for GRAPHICS passes.
// compute_cmd:  command buffer for COMPUTE passes.
// Pass the same buffer for both when async compute is not in use.
run_graph :: proc(
	graph: ^Graph,
	frame_index: u32,
	graphics_cmd: vk.CommandBuffer,
	compute_cmd: vk.CommandBuffer,
) {
	execute(graph, frame_index, graphics_cmd, compute_cmd)
}
