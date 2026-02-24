package render_graph

import vk "vendor:vulkan"
import "core:log"

// Barrier description for synchronization
Barrier :: struct {
	resource_id: ResourceId,
	src_access:  vk.AccessFlags,
	dst_access:  vk.AccessFlags,
	src_stage:   vk.PipelineStageFlags,
	dst_stage:   vk.PipelineStageFlags,
	old_layout:  vk.ImageLayout,  // For images
	new_layout:  vk.ImageLayout,
}

// Resource access tracking
ResourceAccess :: struct {
	access: vk.AccessFlags,
	stage:  vk.PipelineStageFlags,
	layout: vk.ImageLayout,
}

// Compute barriers for all passes
compute_barriers :: proc(g: ^Graph) -> Result {
	// Track last access for each resource
	last_access := make(map[ResourceId]ResourceAccess)
	defer delete(last_access)

	for pass_id in g.execution_order {
		pass := &g.passes[pass_id]
		barriers := make([dynamic]Barrier)

		// Insert barrier for each input resource
		for input_res in pass.inputs {
			if prev_access, has_prev := last_access[input_res]; has_prev {
				barrier := compute_barrier(
					g,
					input_res,
					prev_access,
					infer_read_access(g, pass, input_res),
				)
				// Only add barrier if there's actual transition needed
				if barrier.src_access != barrier.dst_access ||
				   barrier.old_layout != barrier.new_layout {
					append(&barriers, barrier)
				}
			} else {
				// First access within the graph
				desc, ok := get_resource_descriptor(g, input_res)
				if ok && (desc.type == .TEXTURE_2D || desc.type == .DEPTH_TEXTURE) {
					// For imported resources (is_transient = false), assume they're
					// already in the correct layout from previous passes outside the graph
					// For transient resources, transition from UNDEFINED
					initial_access: ResourceAccess
					if desc.is_transient {
						// Transient resource - transition from UNDEFINED
						initial_access = ResourceAccess{
							access = {},
							stage = {.TOP_OF_PIPE},
							layout = .UNDEFINED,
						}
					} else {
						// Imported resource - assume already in expected layout
						// Infer what layout it should be in based on its usage
						initial_access = infer_imported_resource_layout(desc)
					}

					target_access := infer_read_access(g, pass, input_res)

					// Only insert barrier if layout/access actually changes
					if initial_access.layout != target_access.layout ||
					   initial_access.access != target_access.access {
						barrier := compute_barrier(g, input_res, initial_access, target_access)
						append(&barriers, barrier)
					}
				}
			}
		}

		// Update last access for outputs
		for output_res in pass.outputs {
			last_access[output_res] = infer_write_access(g, pass, output_res)
		}

		g.barriers[pass_id] = barriers
	}

	log.infof("Computed barriers for %d passes", len(g.execution_order))
	return .SUCCESS
}

// Get resource descriptor from ID
get_resource_descriptor :: proc(g: ^Graph, res_id: ResourceId) -> (ResourceDescriptor, bool) {
	for name, id in g.resource_ids {
		if id == res_id {
			if desc, ok := g.resources[name]; ok {
				return desc, true
			}
		}
	}
	return {}, false
}

// Infer access flags for read operation
infer_read_access :: proc(g: ^Graph, pass: ^PassInstance, res: ResourceId) -> ResourceAccess {
	desc, ok := get_resource_descriptor(g, res)
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

// Infer access flags for write operation
infer_write_access :: proc(g: ^Graph, pass: ^PassInstance, res: ResourceId) -> ResourceAccess {
	desc, ok := get_resource_descriptor(g, res)
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
			access.access = {.COLOR_ATTACHMENT_WRITE}
			access.layout = .COLOR_ATTACHMENT_OPTIMAL

		case .DEPTH_TEXTURE:
			// Depth/stencil attachment output
			access.stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
			access.access = {.DEPTH_STENCIL_ATTACHMENT_WRITE}
			access.layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
		}
	}

	return access
}

// Infer the initial layout/access of an imported resource
// Imported resources are created outside the graph (e.g., by depth prepass, geometry pass)
// We assume they're already in their expected usage layout
infer_imported_resource_layout :: proc(desc: ResourceDescriptor) -> ResourceAccess {
	access := ResourceAccess{}

	switch desc.type {
	case .DEPTH_TEXTURE:
		// Depth textures are typically left in DEPTH_STENCIL_ATTACHMENT_OPTIMAL
		// after depth prepass/geometry pass
		access.stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
		access.access = {.DEPTH_STENCIL_ATTACHMENT_WRITE}
		access.layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL

	case .TEXTURE_2D, .TEXTURE_CUBE:
		// Check usage flags to determine expected layout
		tex_format, is_tex := desc.format.(TextureFormat)
		if is_tex {
			if .COLOR_ATTACHMENT in tex_format.usage {
				// Color attachment - assume COLOR_ATTACHMENT_OPTIMAL
				access.stage = {.COLOR_ATTACHMENT_OUTPUT}
				access.access = {.COLOR_ATTACHMENT_WRITE}
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

// Compute barrier between two accesses
compute_barrier :: proc(
	g: ^Graph,
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
