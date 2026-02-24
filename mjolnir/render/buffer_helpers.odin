package render

import rg "graph"
import vk "vendor:vulkan"

// Procedural helper to resolve buffer by name
// Supports all bindless buffers in the Manager
resolve_buffer :: proc(
	exec_ctx: ^rg.GraphExecutionContext,
	name: string,
	frame_index: u32,
) -> (rg.ResourceHandle, bool) {
	mgr := cast(^Manager)exec_ctx.render_manager

	switch name {
	case "node_data_buffer":
		return rg.BufferHandle{
			buffer = mgr.node_data_buffer.buffer.buffer,
			size = vk.DeviceSize(mgr.node_data_buffer.buffer.bytes_count),
			descriptor_set = mgr.node_data_buffer.descriptor_set,
		}, true

	case "mesh_data_buffer":
		return rg.BufferHandle{
			buffer = mgr.mesh_data_buffer.buffer.buffer,
			size = vk.DeviceSize(mgr.mesh_data_buffer.buffer.bytes_count),
			descriptor_set = mgr.mesh_data_buffer.descriptor_set,
		}, true

	case "camera_buffer":
		buf := &mgr.camera_buffer.buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
			descriptor_set = mgr.camera_buffer.descriptor_sets[frame_index],
		}, true

	case "bone_buffer":
		buf := &mgr.bone_buffer.buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
			descriptor_set = mgr.bone_buffer.descriptor_sets[frame_index],
		}, true

	case "material_buffer":
		return rg.BufferHandle{
			buffer = mgr.material_buffer.buffer.buffer,
			size = vk.DeviceSize(mgr.material_buffer.buffer.bytes_count),
			descriptor_set = mgr.material_buffer.descriptor_set,
		}, true

	case "lights_buffer":
		return rg.BufferHandle{
			buffer = mgr.lights_buffer.buffer.buffer,
			size = vk.DeviceSize(mgr.lights_buffer.buffer.bytes_count),
			descriptor_set = mgr.lights_buffer.descriptor_set,
		}, true

	case "emitter_buffer":
		return rg.BufferHandle{
			buffer = mgr.emitter_buffer.buffer.buffer,
			size = vk.DeviceSize(mgr.emitter_buffer.buffer.bytes_count),
			descriptor_set = mgr.emitter_buffer.descriptor_set,
		}, true

	case "forcefield_buffer":
		return rg.BufferHandle{
			buffer = mgr.forcefield_buffer.buffer.buffer,
			size = vk.DeviceSize(mgr.forcefield_buffer.buffer.bytes_count),
			descriptor_set = mgr.forcefield_buffer.descriptor_set,
		}, true

	case "sprite_buffer":
		return rg.BufferHandle{
			buffer = mgr.sprite_buffer.buffer.buffer,
			size = vk.DeviceSize(mgr.sprite_buffer.buffer.bytes_count),
			descriptor_set = mgr.sprite_buffer.descriptor_set,
		}, true

	// Particle buffers (from ParticleResources)
	case "particle_buffer":
		return rg.BufferHandle{
			buffer = mgr.particle_resources.particle_buffer.buffer,
			size = vk.DeviceSize(mgr.particle_resources.particle_buffer.bytes_count),
			descriptor_set = {}, // No descriptor set for particle buffer
		}, true

	case "compact_particle_buffer":
		return rg.BufferHandle{
			buffer = mgr.particle_resources.compact_particle_buffer.buffer,
			size = vk.DeviceSize(mgr.particle_resources.compact_particle_buffer.bytes_count),
			descriptor_set = {},
		}, true

	case "draw_command_buffer":
		return rg.BufferHandle{
			buffer = mgr.particle_resources.draw_command_buffer.buffer,
			size = vk.DeviceSize(mgr.particle_resources.draw_command_buffer.bytes_count),
			descriptor_set = {},
		}, true

	// UI buffers (per-frame)
	case "ui_vertex_buffer":
		buf := &mgr.ui.vertex_buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
			descriptor_set = {},
		}, true

	case "ui_index_buffer":
		buf := &mgr.ui.index_buffers[frame_index]
		return rg.BufferHandle{
			buffer = buf.buffer,
			size = vk.DeviceSize(buf.bytes_count),
			descriptor_set = {},
		}, true
	}

	return {}, false
}
