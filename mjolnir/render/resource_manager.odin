package render

import rg "graph"
import "../gpu"
import "camera"
import "shadow"
import vk "vendor:vulkan"
import "core:strings"
import "core:strconv"
import "core:log"

// Design principles (Frostbite-inspired):
// 1. Single resolve function for ALL resources
// 2. Name-based routing to appropriate sub-manager
// 3. Type-safe resolution via ResourceHandle union
// 4. No manual string matching in pass code
//
// Usage:
//   Called automatically by render graph via resolve callbacks
//   rg.register_resource(&g, "particle_buffer", ..., resolve_resource)

resolve_resource :: proc(
	exec_ctx: ^rg.GraphExecutionContext,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	manager := cast(^Manager)exec_ctx.render_manager

	// Route based on name prefix
	if strings.has_prefix(name, "camera_") {
		return resolve_camera_resource(manager, exec_ctx.texture_manager, name, frame_index)
	}

	if strings.has_prefix(name, "shadow_") {
		return resolve_shadow_resource(manager, exec_ctx.texture_manager, name, frame_index)
	}

	// Global and per-frame buffers
	return resolve_buffer_resource(manager, name, frame_index)
}

// ====== BUFFER RESOLUTION ======
// Handles global buffers and per-frame buffers

resolve_buffer_resource :: proc(
	manager: ^Manager,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	switch name {
	// Global buffers (BindlessBuffer)
	case "node_data_buffer":
		return rg.BufferHandle{
			buffer = manager.node_data_buffer.buffer.buffer,
			size = vk.DeviceSize(manager.node_data_buffer.buffer.bytes_count),
			descriptor_set = manager.node_data_buffer.descriptor_set,
		}, true

	case "mesh_data_buffer":
		return rg.BufferHandle{
			buffer = manager.mesh_data_buffer.buffer.buffer,
			size = vk.DeviceSize(manager.mesh_data_buffer.buffer.bytes_count),
			descriptor_set = manager.mesh_data_buffer.descriptor_set,
		}, true

	case "material_buffer":
		return rg.BufferHandle{
			buffer = manager.material_buffer.buffer.buffer,
			size = vk.DeviceSize(manager.material_buffer.buffer.bytes_count),
			descriptor_set = manager.material_buffer.descriptor_set,
		}, true

	case "lights_buffer":
		return rg.BufferHandle{
			buffer = manager.lights_buffer.buffer.buffer,
			size = vk.DeviceSize(manager.lights_buffer.buffer.bytes_count),
			descriptor_set = manager.lights_buffer.descriptor_set,
		}, true

	case "emitter_buffer":
		return rg.BufferHandle{
			buffer = manager.emitter_buffer.buffer.buffer,
			size = vk.DeviceSize(manager.emitter_buffer.buffer.bytes_count),
			descriptor_set = manager.emitter_buffer.descriptor_set,
		}, true

	case "forcefield_buffer":
		return rg.BufferHandle{
			buffer = manager.forcefield_buffer.buffer.buffer,
			size = vk.DeviceSize(manager.forcefield_buffer.buffer.bytes_count),
			descriptor_set = manager.forcefield_buffer.descriptor_set,
		}, true

	case "sprite_buffer":
		return rg.BufferHandle{
			buffer = manager.sprite_buffer.buffer.buffer,
			size = vk.DeviceSize(manager.sprite_buffer.buffer.bytes_count),
			descriptor_set = manager.sprite_buffer.descriptor_set,
		}, true

	// Per-frame buffers (PerFrameBindlessBuffer)
	case "camera_buffer":
		buf := &manager.camera_buffer.buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
			descriptor_set = manager.camera_buffer.descriptor_sets[frame_index],
		}, true

	case "bone_buffer":
		buf := &manager.bone_buffer.buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
			descriptor_set = manager.bone_buffer.descriptor_sets[frame_index],
		}, true

	// Particle resources (MutableBuffer)
	case "particle_buffer":
		return rg.BufferHandle{
			buffer = manager.particle_resources.particle_buffer.buffer,
			size = vk.DeviceSize(manager.particle_resources.particle_buffer.bytes_count),
		}, true

	case "compact_particle_buffer":
		return rg.BufferHandle{
			buffer = manager.particle_resources.compact_particle_buffer.buffer,
			size = vk.DeviceSize(manager.particle_resources.compact_particle_buffer.bytes_count),
		}, true

	case "draw_command_buffer":
		return rg.BufferHandle{
			buffer = manager.particle_resources.draw_command_buffer.buffer,
			size = vk.DeviceSize(manager.particle_resources.draw_command_buffer.bytes_count),
		}, true

	// UI resources (per-frame MutableBuffer)
	case "ui_vertex_buffer":
		buf := &manager.ui.vertex_buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
		}, true

	case "ui_index_buffer":
		buf := &manager.ui.index_buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
		}, true
	}

	log.warnf("Unknown buffer resource: %s", name)
	return {}, false
}

// ====== CAMERA RESOLUTION ======
// Handles per-camera textures and buffers

resolve_camera_resource :: proc(
	manager: ^Manager,
	texture_manager: ^gpu.TextureManager,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Parse name: "camera_5_gbuffer_position" -> cam=5, resource=gbuffer_position
	parts := strings.split(name, "_")
	if len(parts) < 3 {
		delete(parts)
		return {}, false
	}
	defer delete(parts)

	// parts[0] = "camera"
	// parts[1] = camera index
	// parts[2..] = resource name
	cam_index, parse_ok := strconv.parse_uint(parts[1])
	if !parse_ok do return {}, false

	// Get resource name (everything after "camera_X_")
	resource_name := strings.join(parts[2:], "_")
	defer delete(resource_name)

	// Look up camera
	cam, cam_ok := manager.cameras[u32(cam_index)]
	if !cam_ok do return {}, false

	// Check if it's a texture (attachment)
	attachment_type, is_texture := try_parse_attachment_type(resource_name)
	if is_texture {
		handle := cam.attachments[attachment_type][frame_index]
		texture := gpu.get_texture_2d(texture_manager, handle)
		if texture == nil do return {}, false

		// Depth vs color texture
		if attachment_type == .DEPTH {
			return rg.DepthTextureHandle{
				image = texture.image,
				view = texture.view,
				extent = vk.Extent2D{texture.spec.width, texture.spec.height},
			}, true
		}

		return rg.TextureHandle{
			image = texture.image,
			view = texture.view,
			extent = vk.Extent2D{texture.spec.width, texture.spec.height},
			format = texture.spec.format,
		}, true
	}

	// Otherwise it's a buffer (draw commands/count)
	return resolve_camera_buffer_internal(cam, resource_name, frame_index)
}

// Try to parse attachment type from string (returns type + success flag)
try_parse_attachment_type :: proc(name: string) -> (camera.AttachmentType, bool) {
	switch name {
	case "depth":
		return .DEPTH, true
	case "final_image":
		return .FINAL_IMAGE, true
	case "gbuffer_position":
		return .POSITION, true
	case "gbuffer_normal":
		return .NORMAL, true
	case "gbuffer_albedo":
		return .ALBEDO, true
	case "gbuffer_metallic_roughness":
		return .METALLIC_ROUGHNESS, true
	case "gbuffer_emissive":
		return .EMISSIVE, true
	}
	return .FINAL_IMAGE, false
}

// Resolve camera draw buffers (internal helper)
resolve_camera_buffer_internal :: proc(
	cam: camera.Camera,
	buffer_name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	switch buffer_name {
	case "opaque_draw_commands":
		buffer := cam.opaque_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "opaque_draw_count":
		buffer := cam.opaque_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "transparent_draw_commands":
		buffer := cam.transparent_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "transparent_draw_count":
		buffer := cam.transparent_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "wireframe_draw_commands":
		buffer := cam.wireframe_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "wireframe_draw_count":
		buffer := cam.wireframe_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "random_color_draw_commands":
		buffer := cam.random_color_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "random_color_draw_count":
		buffer := cam.random_color_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "line_strip_draw_commands":
		buffer := cam.line_strip_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "line_strip_draw_count":
		buffer := cam.line_strip_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "sprite_draw_commands":
		buffer := cam.sprite_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "sprite_draw_count":
		buffer := cam.sprite_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true
	}

	return {}, false
}

// ====== SHADOW RESOLUTION ======
// Handles per-light shadow resources

resolve_shadow_resource :: proc(
	manager: ^Manager,
	texture_manager: ^gpu.TextureManager,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Shadow maps: "shadow_map_0"
	// Shadow buffers: "shadow_draw_commands_0", "shadow_draw_count_2"

	if strings.has_prefix(name, "shadow_map_") {
		return resolve_shadow_map(manager, texture_manager, name, frame_index)
	}

	if strings.has_prefix(name, "shadow_draw_") {
		return resolve_shadow_buffer_internal(manager, name, frame_index)
	}

	return {}, false
}

// Resolve shadow map texture
resolve_shadow_map :: proc(
	manager: ^Manager,
	texture_manager: ^gpu.TextureManager,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Parse "shadow_map_5" -> slot=5
	parts := strings.split(name, "_")
	if len(parts) < 3 {
		delete(parts)
		return {}, false
	}
	defer delete(parts)

	slot_index, ok := strconv.parse_uint(parts[2])
	if !ok do return {}, false

	slot := u32(slot_index)

	// Check if slot is active
	if !manager.shadow.slot_active[slot] do return {}, false

	kind := manager.shadow.slot_kind[slot]
	switch kind {
	case .SPOT:
		spot := &manager.shadow.spot_lights[slot]
		handle := spot.shadow_map[frame_index]
		texture := gpu.get_texture_2d(texture_manager, handle)
		if texture == nil do return {}, false

		return rg.DepthTextureHandle{
			image = texture.image,
			view = texture.view,
			extent = vk.Extent2D{texture.spec.width, texture.spec.height},
		}, true

	case .DIRECTIONAL:
		directional := &manager.shadow.directional_lights[slot]
		handle := directional.shadow_map[frame_index]
		texture := gpu.get_texture_2d(texture_manager, handle)
		if texture == nil do return {}, false

		return rg.DepthTextureHandle{
			image = texture.image,
			view = texture.view,
			extent = vk.Extent2D{texture.spec.width, texture.spec.height},
		}, true

	case .POINT:
		point := &manager.shadow.point_lights[slot]
		handle := point.shadow_cube[frame_index]
		cube := gpu.get_texture_cube(texture_manager, handle)
		if cube == nil do return {}, false

		return rg.DepthTextureHandle{
			image = cube.image,
			view = cube.view,
			extent = vk.Extent2D{cube.spec.width, cube.spec.height},
		}, true
	}

	return {}, false
}

// Resolve shadow draw buffers (internal helper)
resolve_shadow_buffer_internal :: proc(
	manager: ^Manager,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Parse "shadow_draw_commands_5" -> buffer=draw_commands, slot=5
	parts := strings.split(name, "_")
	if len(parts) < 4 {
		delete(parts)
		return {}, false
	}
	defer delete(parts)

	// parts[0] = "shadow"
	// parts[1] = "draw"
	// parts[2] = "commands" or "count"
	// parts[3] = slot index

	slot_index, ok := strconv.parse_uint(parts[len(parts) - 1])
	if !ok do return {}, false

	slot := u32(slot_index)

	// Check if slot is active
	if !manager.shadow.slot_active[slot] do return {}, false

	// Determine buffer type
	buffer_type := strings.join(parts[1:len(parts) - 1], "_")
	defer delete(buffer_type)

	kind := manager.shadow.slot_kind[slot]
	switch kind {
	case .SPOT:
		spot := &manager.shadow.spot_lights[slot]
		switch buffer_type {
		case "draw_commands":
			buffer := &spot.draw_commands[frame_index]
			return rg.BufferHandle{
				buffer = buffer.buffer,
				size = vk.DeviceSize(buffer.bytes_count),
			}, true
		case "draw_count":
			buffer := &spot.draw_count[frame_index]
			return rg.BufferHandle{
				buffer = buffer.buffer,
				size = vk.DeviceSize(buffer.bytes_count),
			}, true
		}

	case .DIRECTIONAL:
		directional := &manager.shadow.directional_lights[slot]
		switch buffer_type {
		case "draw_commands":
			buffer := &directional.draw_commands[frame_index]
			return rg.BufferHandle{
				buffer = buffer.buffer,
				size = vk.DeviceSize(buffer.bytes_count),
			}, true
		case "draw_count":
			buffer := &directional.draw_count[frame_index]
			return rg.BufferHandle{
				buffer = buffer.buffer,
				size = vk.DeviceSize(buffer.bytes_count),
			}, true
		}

	case .POINT:
		point := &manager.shadow.point_lights[slot]
		switch buffer_type {
		case "draw_commands":
			buffer := &point.draw_commands[frame_index]
			return rg.BufferHandle{
				buffer = buffer.buffer,
				size = vk.DeviceSize(buffer.bytes_count),
			}, true
		case "draw_count":
			buffer := &point.draw_count[frame_index]
			return rg.BufferHandle{
				buffer = buffer.buffer,
				size = vk.DeviceSize(buffer.bytes_count),
			}, true
		}
	}

	return {}, false
}
