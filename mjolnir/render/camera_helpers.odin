package render

import rg "graph"
import "camera"
import "../gpu"
import "core:strings"
import "core:strconv"
import vk "vendor:vulkan"

// Procedural helper to resolve camera texture by name
// Examples: "camera_0_depth", "camera_1_gbuffer_position", "camera_2_final_image"
resolve_camera_texture :: proc(
	exec_ctx: ^rg.GraphExecutionContext,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Parse name: "camera_5_gbuffer_position" -> cam=5, attachment=POSITION
	parts := strings.split(name, "_")
	if len(parts) < 3 do return {}, false
	defer delete(parts)

	// parts[0] = "camera"
	// parts[1] = camera index (e.g., "0", "1", "2")
	// parts[2..] = attachment name (e.g., "depth", "gbuffer", "position")

	cam_index, ok := strconv.parse_uint(parts[1])
	if !ok do return {}, false

	// Get attachment name (everything after "camera_X_")
	attachment_name := strings.join(parts[2:], "_")
	defer delete(attachment_name)

	// Access cameras from render manager (passed via execution context)
	manager := cast(^Manager)exec_ctx.render_manager
	cam, cam_ok := manager.cameras[u32(cam_index)]
	if !cam_ok do return {}, false

	// Parse attachment type from name
	attachment_type := parse_attachment_type(attachment_name)
	handle := cam.attachments[attachment_type][frame_index]
	texture := gpu.get_texture_2d(exec_ctx.texture_manager, handle)

	if texture == nil {
		return {}, false
	}

	// Check if it's a depth texture
	if attachment_type == .DEPTH {
		return rg.DepthTextureHandle{
			image = texture.image,
			view = texture.view,
			extent = vk.Extent2D{texture.spec.width, texture.spec.height},
		}, true
	}

	// Regular color texture
	return rg.TextureHandle{
		image = texture.image,
		view = texture.view,
		extent = vk.Extent2D{texture.spec.width, texture.spec.height},
		format = texture.spec.format,
	}, true
}

// Parse attachment type from string name
parse_attachment_type :: proc(name: string) -> camera.AttachmentType {
	switch name {
	case "depth":
		return .DEPTH
	case "final_image":
		return .FINAL_IMAGE
	case "gbuffer_position":
		return .POSITION
	case "gbuffer_normal":
		return .NORMAL
	case "gbuffer_albedo":
		return .ALBEDO
	case "gbuffer_metallic_roughness":
		return .METALLIC_ROUGHNESS
	case "gbuffer_emissive":
		return .EMISSIVE
	}
	// Default to final image if unknown
	return .FINAL_IMAGE
}

// Procedural helper to resolve camera-specific buffers by name
// Examples: "camera_0_opaque_draw_commands", "camera_1_opaque_draw_count"
resolve_camera_buffer :: proc(
	exec_ctx: ^rg.GraphExecutionContext,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Parse name: "camera_5_opaque_draw_commands" -> cam=5, buffer=opaque_draw_commands
	parts := strings.split(name, "_")
	if len(parts) < 3 do return {}, false
	defer delete(parts)

	// parts[0] = "camera"
	// parts[1] = camera index
	// parts[2..] = buffer name (e.g., "opaque", "draw", "commands")

	cam_index, ok := strconv.parse_uint(parts[1])
	if !ok do return {}, false

	// Get buffer name (everything after "camera_X_")
	buffer_name := strings.join(parts[2:], "_")
	defer delete(buffer_name)

	// Access cameras from render manager
	manager := cast(^Manager)exec_ctx.render_manager
	cam, cam_ok := manager.cameras[u32(cam_index)]
	if !cam_ok do return {}, false

	// Resolve camera-specific buffers
	switch buffer_name {
	case "opaque_draw_commands":
		buffer := &cam.opaque_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "opaque_draw_count":
		buffer := &cam.opaque_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "transparent_draw_commands":
		buffer := &cam.transparent_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "transparent_draw_count":
		buffer := &cam.transparent_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "wireframe_draw_commands":
		buffer := &cam.wireframe_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "wireframe_draw_count":
		buffer := &cam.wireframe_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "random_color_draw_commands":
		buffer := &cam.random_color_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "random_color_draw_count":
		buffer := &cam.random_color_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "line_strip_draw_commands":
		buffer := &cam.line_strip_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "line_strip_draw_count":
		buffer := &cam.line_strip_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "sprite_draw_commands":
		buffer := &cam.sprite_draw_commands[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true

	case "sprite_draw_count":
		buffer := &cam.sprite_draw_count[frame_index]
		return rg.BufferHandle{
			buffer = buffer.buffer,
			size = vk.DeviceSize(buffer.bytes_count),
		}, true
	}

	return {}, false
}
