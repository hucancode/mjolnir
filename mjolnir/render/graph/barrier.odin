package render_graph

import vk "vendor:vulkan"
import "core:log"

// ============================================================================
// INTERNAL TYPES - Barrier computation implementation
// ============================================================================

Barrier :: struct {
	resource_id: ResourceId,
	src_access:  vk.AccessFlags,
	dst_access:  vk.AccessFlags,
	src_stage:   vk.PipelineStageFlags,
	dst_stage:   vk.PipelineStageFlags,
	old_layout:  vk.ImageLayout,  // For images
	new_layout:  vk.ImageLayout,
}

ResourceAccess :: struct {
	access: vk.AccessFlags,
	stage:  vk.PipelineStageFlags,
	layout: vk.ImageLayout,
}

// ============================================================================
// PRIVATE BARRIER COMPUTATION
// ============================================================================

@(private)
_has_access_transition :: proc(src, dst: ResourceAccess) -> bool {
	return src.access != dst.access ||
		src.stage != dst.stage ||
		src.layout != dst.layout
}

@(private)
_resource_written_in_pass :: proc(pass: ^PassInstance, res: ResourceId) -> bool {
	for output_res in pass.outputs {
		if output_res == res {
			return true
		}
	}
	return false
}

@(private)
_initial_access_for_resource :: proc(g: ^Graph, res_id: ResourceId) -> (ResourceAccess, bool) {
	desc, ok := _get_resource_descriptor(g, res_id)
	if !ok {
		return {}, false
	}
	if desc.is_transient {
		return ResourceAccess{
			access = {},
			stage = {.TOP_OF_PIPE},
			layout = .UNDEFINED,
		}, true
	}
	access := _infer_imported_resource_layout(desc)
	if access.stage == {} {
		access.stage = {.TOP_OF_PIPE}
	}
	return access, true
}

@(private)
_append_transition_barrier :: proc(
	barriers: ^[dynamic]Barrier,
	res_id: ResourceId,
	src, dst: ResourceAccess,
) {
	if !_has_access_transition(src, dst) {
		return
	}
	append(barriers, _compute_barrier(
		res_id,
		src,
		dst,
	))
}

@(private)
_compute_barriers :: proc(g: ^Graph) -> Result {
	// Track last access for each resource
	last_access := make(map[ResourceId]ResourceAccess)
	defer delete(last_access)

	for pass_id in g.execution_order {
		pass := &g.passes[pass_id]
		barriers := make([dynamic]Barrier)
		seen_inputs := make(map[ResourceId]bool)
		seen_outputs := make(map[ResourceId]bool)

		// Insert barriers for reads (skip read/write resources, handled by write pass)
		for input_res in pass.inputs {
			if _, already_seen := seen_inputs[input_res]; already_seen {
				continue
			}
			seen_inputs[input_res] = true
			if _resource_written_in_pass(pass, input_res) {
				continue
			}
			target_access := _infer_read_access(g, pass, input_res)
			if prev_access, has_prev := last_access[input_res]; has_prev {
				_append_transition_barrier(
					&barriers,
					input_res,
					prev_access,
					target_access,
				)
			} else if initial_access, ok := _initial_access_for_resource(g, input_res); ok {
				_append_transition_barrier(&barriers, input_res, initial_access, target_access)
			}
			last_access[input_res] = target_access
		}

		// Insert barriers for writes
		for output_res in pass.outputs {
			if _, already_seen := seen_outputs[output_res]; already_seen {
				continue
			}
			seen_outputs[output_res] = true

			target_access := _infer_write_access(g, pass, output_res)
			if prev_access, has_prev := last_access[output_res]; has_prev {
				_append_transition_barrier(
					&barriers,
					output_res,
					prev_access,
					target_access,
				)
			} else if initial_access, ok := _initial_access_for_resource(g, output_res); ok {
				_append_transition_barrier(&barriers, output_res, initial_access, target_access)
			}
			last_access[output_res] = target_access
		}
		delete(seen_inputs)
		delete(seen_outputs)

		g.barriers[pass_id] = barriers
	}

	log.infof("Computed barriers for %d passes", len(g.execution_order))
	return .SUCCESS
}

@(private)
_infer_read_access :: proc(g: ^Graph, pass: ^PassInstance, res: ResourceId) -> ResourceAccess {
	desc, ok := _get_resource_descriptor(g, res)
	if !ok {
		return {}
	}

	access := ResourceAccess{}

	switch pass.queue {
	case .COMPUTE:
		// Compute shader reading
		access.stage = {.COMPUTE_SHADER}
		switch desc.type {
		case .BUFFER:
			access.access = {.SHADER_READ}
			access.layout = .UNDEFINED // Buffers don't have layouts
		case .TEXTURE_2D, .TEXTURE_CUBE:
			access.access = {.SHADER_READ}
			access.layout = .SHADER_READ_ONLY_OPTIMAL
		case .DEPTH_TEXTURE:
			access.access = {.SHADER_READ}
			access.layout = .SHADER_READ_ONLY_OPTIMAL
		}

	case .GRAPHICS:
		// Graphics pipeline reading
		switch desc.type {
		case .BUFFER:
			// Buffers can be vertex, index, or indirect
			access.stage = {.VERTEX_INPUT}
			access.access = {.VERTEX_ATTRIBUTE_READ, .INDEX_READ, .INDIRECT_COMMAND_READ}
			access.layout = .UNDEFINED

		case .TEXTURE_2D, .TEXTURE_CUBE:
			// Texture sampling in fragment shader
			access.stage = {.FRAGMENT_SHADER}
			access.access = {.SHADER_READ}
			access.layout = .SHADER_READ_ONLY_OPTIMAL

		case .DEPTH_TEXTURE:
			// Depth testing
			access.stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
			access.access = {.DEPTH_STENCIL_ATTACHMENT_READ}
			access.layout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL
		}
	}

	return access
}

@(private)
_infer_write_access :: proc(g: ^Graph, pass: ^PassInstance, res: ResourceId) -> ResourceAccess {
	desc, ok := _get_resource_descriptor(g, res)
	if !ok {
		return {}
	}

	access := ResourceAccess{}

	switch pass.queue {
	case .COMPUTE:
		// Compute shader writing
		access.stage = {.COMPUTE_SHADER}
		switch desc.type {
		case .BUFFER:
			access.access = {.SHADER_WRITE}
			access.layout = .UNDEFINED
		case .TEXTURE_2D, .TEXTURE_CUBE:
			access.access = {.SHADER_WRITE}
			access.layout = .GENERAL
		case .DEPTH_TEXTURE:
			access.access = {.SHADER_WRITE}
			access.layout = .GENERAL
		}

	case .GRAPHICS:
		// Graphics pipeline writing
		switch desc.type {
		case .BUFFER:
			// Graphics doesn't typically write to buffers directly
			access.stage = {.VERTEX_SHADER}
			access.access = {.SHADER_WRITE}
			access.layout = .UNDEFINED

		case .TEXTURE_2D, .TEXTURE_CUBE:
			// Color attachment output
			access.stage = {.COLOR_ATTACHMENT_OUTPUT}
			access.access = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
			access.layout = .COLOR_ATTACHMENT_OPTIMAL

		case .DEPTH_TEXTURE:
			// Depth/stencil attachment output
			access.stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
			access.access = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
			access.layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
		}
	}

	return access
}

@(private)
_infer_imported_resource_layout :: proc(desc: ResourceDescriptor) -> ResourceAccess {
	access := ResourceAccess{}

	switch desc.type {
	case .DEPTH_TEXTURE:
		// Depth textures are typically left in DEPTH_STENCIL_ATTACHMENT_OPTIMAL
		// after depth prepass/geometry pass
		access.stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
		access.access = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
		access.layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL

	case .TEXTURE_2D, .TEXTURE_CUBE:
		// Check usage flags to determine expected layout
		tex_format, is_tex := desc.format.(TextureFormat)
		if is_tex {
			if .COLOR_ATTACHMENT in tex_format.usage {
				// Color attachment - assume COLOR_ATTACHMENT_OPTIMAL
				access.stage = {.COLOR_ATTACHMENT_OUTPUT}
				access.access = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
				access.layout = .COLOR_ATTACHMENT_OPTIMAL
			} else if .SAMPLED in tex_format.usage {
				// Sampled texture - assume SHADER_READ_ONLY_OPTIMAL
				access.stage = {.FRAGMENT_SHADER}
				access.access = {.SHADER_READ}
				access.layout = .SHADER_READ_ONLY_OPTIMAL
			} else {
				// Default to GENERAL for other cases
				access.stage = {.FRAGMENT_SHADER}
				access.access = {.SHADER_READ}
				access.layout = .GENERAL
			}
		}

	case .BUFFER:
		// Buffers don't have layouts
		access.layout = .UNDEFINED
	}

	return access
}

@(private)
_compute_barrier :: proc(
	res_id: ResourceId,
	src: ResourceAccess,
	dst: ResourceAccess,
) -> Barrier {
	return Barrier{
		resource_id = res_id,
		src_access = src.access,
		dst_access = dst.access,
		src_stage = src.stage,
		dst_stage = dst.stage,
		old_layout = src.layout,
		new_layout = dst.layout,
	}
}
