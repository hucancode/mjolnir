package render_graph

import "../../gpu"
import vk "vendor:vulkan"

ResourceId :: distinct u32

INVALID_RESOURCE :: ResourceId(0)

// Resolve callbacks - called at execute time with frame_index
ImageResolveProc :: #type proc(
	user_data: rawptr,
	frame_index: u32,
) -> (
	image: vk.Image,
	view: vk.ImageView,
	extent: vk.Extent2D,
)

BufferResolveProc :: #type proc(
	user_data: rawptr,
	frame_index: u32,
) -> (
	buffer: vk.Buffer,
	size: vk.DeviceSize,
)

CameraResolveProc :: #type proc(
	user_data: rawptr,
	frame_index: u32,
) -> (
	camera_index: u32,
	descriptor_set: vk.DescriptorSet,
)

// Resource variants
ColorTexture :: struct {
	format:    vk.Format,
	resolve:   ImageResolveProc,
	user_data: rawptr,
}

DepthTexture :: struct {
	format:    vk.Format,
	resolve:   ImageResolveProc,
	user_data: rawptr,
}

CubeTexture :: struct {
	format:      vk.Format,
	layer_count: u32,
	resolve:     ImageResolveProc,
	user_data:   rawptr,
}

BufferResource :: struct {
	resolve:   BufferResolveProc,
	user_data: rawptr,
}

SwapchainResource :: struct {
	resolve:   ImageResolveProc,
	user_data: rawptr,
}

// CameraData: input-only, no barriers needed
CameraData :: struct {
	resolve:   CameraResolveProc,
	user_data: rawptr,
}

// Transient resources - graph-owned, allocated/freed each frame
TransientTexture :: struct {
	format: vk.Format,
	extent: vk.Extent2D,
	usage:  vk.ImageUsageFlags,
}

TransientBuffer :: struct {
	element_size:  u32,
	element_count: u32,
	usage:         vk.BufferUsageFlags,
}

Resource :: union {
	ColorTexture,
	DepthTexture,
	CubeTexture,
	BufferResource,
	SwapchainResource,
	CameraData,
	TransientTexture,
	TransientBuffer,
}

// Resolved handles at execute time
ResolvedImage :: struct {
	image:  vk.Image,
	view:   vk.ImageView,
	extent: vk.Extent2D,
}

ResolvedBuffer :: struct {
	buffer: vk.Buffer,
	size:   vk.DeviceSize,
}

ResolvedCamera :: struct {
	camera_index:   u32,
	descriptor_set: vk.DescriptorSet,
}

// Registration procs - add resources to a graph
add_color_texture :: proc(
	g: ^Graph,
	name: string,
	format: vk.Format,
	resolve: ImageResolveProc,
	user_data: rawptr,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(ColorTexture{format = format, resolve = resolve, user_data = user_data})
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

add_depth_texture :: proc(
	g: ^Graph,
	name: string,
	format: vk.Format,
	resolve: ImageResolveProc,
	user_data: rawptr,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(DepthTexture{format = format, resolve = resolve, user_data = user_data})
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

add_cube_texture :: proc(
	g: ^Graph,
	name: string,
	format: vk.Format,
	layer_count: u32,
	resolve: ImageResolveProc,
	user_data: rawptr,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(
		CubeTexture{format = format, layer_count = layer_count, resolve = resolve, user_data = user_data},
	)
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

add_buffer :: proc(
	g: ^Graph,
	name: string,
	resolve: BufferResolveProc,
	user_data: rawptr,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(BufferResource{resolve = resolve, user_data = user_data})
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

add_swapchain :: proc(
	g: ^Graph,
	name: string,
	resolve: ImageResolveProc,
	user_data: rawptr,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(SwapchainResource{resolve = resolve, user_data = user_data})
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

add_camera :: proc(
	g: ^Graph,
	name: string,
	resolve: CameraResolveProc,
	user_data: rawptr,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(CameraData{resolve = resolve, user_data = user_data})
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

add_transient_color_texture :: proc(
	g: ^Graph,
	name: string,
	format: vk.Format,
	extent: vk.Extent2D,
	usage: vk.ImageUsageFlags,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(TransientTexture{format = format, extent = extent, usage = usage})
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

add_transient_buffer :: proc(
	g: ^Graph,
	name: string,
	element_size: u32,
	element_count: u32,
	usage: vk.BufferUsageFlags,
) -> ResourceId {
	id := g.next_resource_id
	g.next_resource_id += 1
	res := Resource(TransientBuffer{element_size = element_size, element_count = element_count, usage = usage})
	g.resources[id] = ResourceEntry{name = name, resource = res}
	return id
}

// Resolve a resource to its concrete handles at frame time
resolve_image :: proc(
	g: ^Graph,
	resource_id: ResourceId,
	resource: Resource,
	frame_index: u32,
	texture_manager: ^gpu.TextureManager,
) -> (
	resolved: ResolvedImage,
	ok: bool,
) {
	switch r in resource {
	case ColorTexture:
		img, view, extent := r.resolve(r.user_data, frame_index)
		if img == 0 do return {}, false
		return ResolvedImage{image = img, view = view, extent = extent}, true
	case DepthTexture:
		img, view, extent := r.resolve(r.user_data, frame_index)
		if img == 0 do return {}, false
		return ResolvedImage{image = img, view = view, extent = extent}, true
	case CubeTexture:
		img, view, extent := r.resolve(r.user_data, frame_index)
		if img == 0 do return {}, false
		return ResolvedImage{image = img, view = view, extent = extent}, true
	case SwapchainResource:
		img, view, extent := r.resolve(r.user_data, frame_index)
		if img == 0 do return {}, false
		return ResolvedImage{image = img, view = view, extent = extent}, true
	case TransientTexture:
		// Look up transient texture from graph storage
		handle, has_handle := g.transient_textures[resource_id]
		if !has_handle do return {}, false
		tex := gpu.get_texture_2d(texture_manager, handle)
		if tex == nil do return {}, false
		return ResolvedImage{image = tex.image, view = tex.view, extent = tex.spec.extent}, true
	case BufferResource, TransientBuffer, CameraData:
		return {}, false
	}
	return {}, false
}

resolve_buffer :: proc(
	g: ^Graph,
	resource_id: ResourceId,
	resource: Resource,
	frame_index: u32,
) -> (
	resolved: ResolvedBuffer,
	ok: bool,
) {
	if r, ok2 := resource.(BufferResource); ok2 {
		buf, size := r.resolve(r.user_data, frame_index)
		if buf == 0 do return {}, false
		return ResolvedBuffer{buffer = buf, size = size}, true
	}
	if _, ok2 := resource.(TransientBuffer); ok2 {
		// Look up transient buffer from graph storage
		alloc, has_alloc := g.transient_buffers[resource_id]
		if !has_alloc do return {}, false
		return ResolvedBuffer{buffer = alloc.buffer, size = alloc.size}, true
	}
	return {}, false
}

resolve_camera :: proc(
	resource: Resource,
	frame_index: u32,
) -> (
	resolved: ResolvedCamera,
	ok: bool,
) {
	if r, ok2 := resource.(CameraData); ok2 {
		cam_index, desc_set := r.resolve(r.user_data, frame_index)
		return ResolvedCamera{camera_index = cam_index, descriptor_set = desc_set}, true
	}
	return {}, false
}
