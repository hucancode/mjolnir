package render_graph

import vk "vendor:vulkan"

// ============================================================================
// Public API - Main Entry Points
// ============================================================================

// This file provides a clean public API for the frame graph system.
// Users should primarily use these functions.

// Create and compile a frame graph from pass declarations
build_graph :: proc(
	pass_decls: []PassDecl,
	ctx: CompileContext,
	loc := #caller_location,
) -> (graph: Graph, err: CompileError) {
	// Compile graph
	graph, err = compile(pass_decls, ctx, loc)
	if err != .NONE {
		return {}, err
	}

	// Allocate resources
	err = allocate_resources(&graph, ctx.gctx, loc)
	if err != .NONE {
		destroy(&graph, ctx.gctx)
		return {}, err
	}

	// Compute barriers
	compute_barriers(&graph)

	return graph, .NONE
}

// Execute compiled graph for a frame
run_graph :: proc(
	graph: ^Graph,
	frame_index: u32,
	cmd: vk.CommandBuffer,
) {
	execute(graph, frame_index, cmd)
}

// Rebuild graph (recompile with new topology)
rebuild_graph :: proc(
	graph: ^Graph,
	pass_decls: []PassDecl,
	ctx: CompileContext,
	loc := #caller_location,
) -> CompileError {
	// Reset existing graph
	reset(graph)

	// Recompile
	new_graph, err := compile(pass_decls, ctx, loc)
	if err != .NONE {
		return err
	}

	// Copy new graph data into existing graph
	graph^ = new_graph

	// Allocate resources
	err = allocate_resources(graph, ctx.gctx, loc)
	if err != .NONE {
		return err
	}

	// Compute barriers
	compute_barriers(graph)

	return .NONE
}
