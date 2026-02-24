package render_graph

import "../../gpu"
import vk "vendor:vulkan"
import "base:intrinsics"

// Resource identification (human-readable, stable key)
ResourceId :: distinct string

// Resource scope determines instantiation behavior
ResourceScope :: enum {
	GLOBAL,      // Shared across all cameras/lights (e.g., particle_buffer)
	PER_FRAME,   // Per-frame buffered (e.g., camera_buffer[frame_index])
	PER_CAMERA,  // Per-camera instance (e.g., camera_0_depth)
	PER_LIGHT,   // Per-light instance (e.g., shadow_map_light_3)
}

// Resource type classification
ResourceType :: enum {
	BUFFER,
	TEXTURE_2D,
	TEXTURE_CUBE,
	DEPTH_TEXTURE,
}

// Resource format descriptors
ResourceFormat :: union {
	BufferFormat,
	TextureFormat,
}

BufferFormat :: struct {
	element_size:  uint,
	element_count: uint,
	usage:         vk.BufferUsageFlags,
}

TextureFormat :: struct {
	width, height: u32,
	format:        vk.Format,
	usage:         vk.ImageUsageFlags,
	mip_levels:    u32,
}

// Forward declaration for execution context
GraphExecutionContext :: struct {
	texture_manager: ^gpu.TextureManager,
	render_manager:  rawptr, // ^render.Manager (to avoid circular import)
}

// Resource resolution callback - maps resource ID to actual GPU handle
// Takes execution context as parameter (NOT stored in struct!)
ResourceResolveProc :: #type proc(
	ctx: ^GraphExecutionContext,
	resource_id: string,
	frame_index: u32,
) -> (ResourceHandle, bool)

// Resource descriptor - defines a resource in the graph
ResourceDescriptor :: struct {
	scope:        ResourceScope,
	type:         ResourceType,
	format:       ResourceFormat,
	is_transient: bool,           // Transient vs imported resource
	resolve:      ResourceResolveProc, // How to get actual GPU handle
}

// Type-safe resource handles (like Frostbite's FrameGraphResources)
ResourceHandle :: union {
	BufferHandle,
	TextureHandle,
	DepthTextureHandle,
}

BufferHandle :: struct {
	buffer:         vk.Buffer,
	size:           vk.DeviceSize,
	descriptor_set: vk.DescriptorSet, // For bindless access
}

TextureHandle :: struct {
	image:  vk.Image,
	view:   vk.ImageView,
	extent: vk.Extent2D,
	format: vk.Format,
}

DepthTextureHandle :: struct {
	image:  vk.Image,
	view:   vk.ImageView,
	extent: vk.Extent2D,
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_infer_resource_type :: proc(format: ResourceFormat) -> ResourceType {
	switch _ in format {
	case BufferFormat:
		return .BUFFER
	case TextureFormat:
		tex_fmt := format.(TextureFormat)
		// Check if it's a depth format
		if _is_depth_format(tex_fmt.format) {
			return .DEPTH_TEXTURE
		}
		return .TEXTURE_2D
	}
	return .BUFFER
}

@(private)
_is_depth_format :: proc(format: vk.Format) -> bool {
	#partial switch format {
	case .D16_UNORM, .D32_SFLOAT, .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT, .D32_SFLOAT_S8_UINT:
		return true
	}
	return false
}
