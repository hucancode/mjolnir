package render_graph

import vk "vendor:vulkan"

// Infer the required Vulkan resource state for a given resource type and access mode.
// Returns the target ResourceState and aspect mask for image barriers.
infer_required_state :: proc(
	resource: Resource,
	access: AccessMode,
	queue: QueueType,
) -> (
	state: ResourceState,
	aspect: vk.ImageAspectFlags,
) {
	switch r in resource {
	case ColorTexture:
		aspect = {.COLOR}
		switch access {
		case .READ:
			stage := queue == .COMPUTE ? vk.PipelineStageFlags{.COMPUTE_SHADER} : vk.PipelineStageFlags{.FRAGMENT_SHADER}
			state = ResourceState {
				layout = .SHADER_READ_ONLY_OPTIMAL,
				access = {.SHADER_READ},
				stage  = stage,
			}
		case .WRITE:
			state = ResourceState {
				layout = .COLOR_ATTACHMENT_OPTIMAL,
				access = {.COLOR_ATTACHMENT_WRITE},
				stage  = {.COLOR_ATTACHMENT_OUTPUT},
			}
		case .READ_WRITE:
			state = ResourceState {
				layout = .COLOR_ATTACHMENT_OPTIMAL,
				access = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
				stage  = {.COLOR_ATTACHMENT_OUTPUT},
			}
		}

	case DepthTexture:
		aspect = {.DEPTH}
		switch access {
		case .READ:
			stage := queue == .COMPUTE ? vk.PipelineStageFlags{.COMPUTE_SHADER} : vk.PipelineStageFlags{.FRAGMENT_SHADER, .EARLY_FRAGMENT_TESTS}
			state = ResourceState {
				layout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
				access = {.SHADER_READ},
				stage  = stage,
			}
		case .WRITE:
			state = ResourceState {
				layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
				access = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
				stage  = {.EARLY_FRAGMENT_TESTS},
			}
		case .READ_WRITE:
			state = ResourceState {
				layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
				access = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
				stage  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			}
		}

	case CubeTexture:
		aspect = {.COLOR}
		switch access {
		case .READ:
			stage := queue == .COMPUTE ? vk.PipelineStageFlags{.COMPUTE_SHADER} : vk.PipelineStageFlags{.FRAGMENT_SHADER}
			state = ResourceState {
				layout = .SHADER_READ_ONLY_OPTIMAL,
				access = {.SHADER_READ},
				stage  = stage,
			}
		case .WRITE:
			state = ResourceState {
				layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
				access = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
				stage  = {.EARLY_FRAGMENT_TESTS},
			}
		case .READ_WRITE:
			state = ResourceState {
				layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
				access = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
				stage  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			}
		}

	case BufferResource:
		aspect = {}
		switch access {
		case .READ:
			stage := queue == .COMPUTE ? vk.PipelineStageFlags{.COMPUTE_SHADER} : vk.PipelineStageFlags{.DRAW_INDIRECT, .VERTEX_SHADER}
			state = ResourceState {
				layout = .UNDEFINED,
				access = {.SHADER_READ, .INDIRECT_COMMAND_READ},
				stage  = stage,
			}
		case .WRITE:
			state = ResourceState {
				layout = .UNDEFINED,
				access = {.SHADER_WRITE},
				stage  = {.COMPUTE_SHADER},
			}
		case .READ_WRITE:
			state = ResourceState {
				layout = .UNDEFINED,
				access = {.SHADER_READ, .SHADER_WRITE},
				stage  = {.COMPUTE_SHADER},
			}
		}

	case SwapchainResource:
		aspect = {.COLOR}
		// Swapchain is always a write target (present src after)
		state = ResourceState {
			layout = .COLOR_ATTACHMENT_OPTIMAL,
			access = {.COLOR_ATTACHMENT_WRITE},
			stage  = {.COLOR_ATTACHMENT_OUTPUT},
		}

	case TransientTexture:
		// Transient textures behave like color textures
		aspect = {.COLOR}
		switch access {
		case .READ:
			stage := queue == .COMPUTE ? vk.PipelineStageFlags{.COMPUTE_SHADER} : vk.PipelineStageFlags{.FRAGMENT_SHADER}
			state = ResourceState {
				layout = .SHADER_READ_ONLY_OPTIMAL,
				access = {.SHADER_READ},
				stage  = stage,
			}
		case .WRITE:
			state = ResourceState {
				layout = .COLOR_ATTACHMENT_OPTIMAL,
				access = {.COLOR_ATTACHMENT_WRITE},
				stage  = {.COLOR_ATTACHMENT_OUTPUT},
			}
		case .READ_WRITE:
			state = ResourceState {
				layout = .COLOR_ATTACHMENT_OPTIMAL,
				access = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
				stage  = {.COLOR_ATTACHMENT_OUTPUT},
			}
		}

	case TransientBuffer:
		// Transient buffers behave like buffer resources
		aspect = {}
		switch access {
		case .READ:
			stage := queue == .COMPUTE ? vk.PipelineStageFlags{.COMPUTE_SHADER} : vk.PipelineStageFlags{.DRAW_INDIRECT, .VERTEX_SHADER}
			state = ResourceState {
				layout = .UNDEFINED,
				access = {.SHADER_READ, .INDIRECT_COMMAND_READ},
				stage  = stage,
			}
		case .WRITE:
			state = ResourceState {
				layout = .UNDEFINED,
				access = {.SHADER_WRITE},
				stage  = {.COMPUTE_SHADER},
			}
		case .READ_WRITE:
			state = ResourceState {
				layout = .UNDEFINED,
				access = {.SHADER_READ, .SHADER_WRITE},
				stage  = {.COMPUTE_SHADER},
			}
		}

	case CameraData:
		// Camera data never needs barriers - it's persistently mapped
		aspect = {}
		state = INITIAL_RESOURCE_STATE
	}

	return state, aspect
}
