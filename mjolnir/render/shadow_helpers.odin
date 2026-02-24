package render

import rg "graph"
import "shadow"
import "../gpu"
import "core:strings"
import "core:strconv"
import vk "vendor:vulkan"

// Procedural helper to resolve shadow buffer by name
// Examples: "shadow_draw_commands_0", "shadow_draw_count_2"
resolve_shadow_buffer :: proc(
	exec_ctx: ^rg.GraphExecutionContext,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Parse name: "shadow_draw_commands_5" -> slot=5, buffer=draw_commands
	parts := strings.split(name, "_")
	if len(parts) < 3 do return {}, false
	defer delete(parts)

	// parts[0] = "shadow"
	// parts[1] = "draw"
	// parts[2] = "commands"/"count"
	// parts[3] = slot index

	slot_index, ok := strconv.parse_uint(parts[len(parts) - 1])
	if !ok do return {}, false

	// Access shadow system from render manager
	manager := cast(^Manager)exec_ctx.render_manager
	slot := u32(slot_index)

	// Check if slot is active
	if !manager.shadow.slot_active[slot] {
		return {}, false
	}

	// Determine buffer type from name
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

// Procedural helper to resolve shadow texture by name
// Examples: "shadow_map_0", "shadow_map_5"
resolve_shadow_texture :: proc(
	exec_ctx: ^rg.GraphExecutionContext,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	// Parse name: "shadow_map_5" -> slot=5
	parts := strings.split(name, "_")
	if len(parts) < 3 do return {}, false
	defer delete(parts)

	// parts[0] = "shadow"
	// parts[1] = "map"
	// parts[2] = slot index

	slot_index, ok := strconv.parse_uint(parts[2])
	if !ok do return {}, false

	// Access shadow system from render manager
	manager := cast(^Manager)exec_ctx.render_manager
	slot := u32(slot_index)

	// Check if slot is active
	if !manager.shadow.slot_active[slot] {
		return {}, false
	}

	kind := manager.shadow.slot_kind[slot]
	switch kind {
	case .SPOT:
		spot := &manager.shadow.spot_lights[slot]
		handle := spot.shadow_map[frame_index]
		texture := gpu.get_texture_2d(exec_ctx.texture_manager, handle)
		if texture == nil do return {}, false

		return rg.DepthTextureHandle{
			image = texture.image,
			view = texture.view,
			extent = vk.Extent2D{texture.spec.width, texture.spec.height},
		}, true

	case .DIRECTIONAL:
		directional := &manager.shadow.directional_lights[slot]
		handle := directional.shadow_map[frame_index]
		texture := gpu.get_texture_2d(exec_ctx.texture_manager, handle)
		if texture == nil do return {}, false

		return rg.DepthTextureHandle{
			image = texture.image,
			view = texture.view,
			extent = vk.Extent2D{texture.spec.width, texture.spec.height},
		}, true

	case .POINT:
		point := &manager.shadow.point_lights[slot]
		handle := point.shadow_cube[frame_index]
		cube := gpu.get_texture_cube(exec_ctx.texture_manager, handle)
		if cube == nil do return {}, false

		return rg.DepthTextureHandle{
			image = cube.image,
			view = cube.view,
			extent = vk.Extent2D{cube.spec.width, cube.spec.height},
		}, true
	}

	return {}, false
}
