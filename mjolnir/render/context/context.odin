package render_context

// context.odin: Shared context types for render passes.
// This package avoids circular dependencies between render and its submodules.

import vk "vendor:vulkan"

// RenderContext bundles all bindless descriptor sets and global buffers
// that are shared across render passes within a frame.
RenderContext :: struct {
	// Bindless descriptor sets (frame-invariant or updated per-frame)
	cameras_descriptor_set:         vk.DescriptorSet,
	textures_descriptor_set:        vk.DescriptorSet,
	bone_descriptor_set:            vk.DescriptorSet,
	material_descriptor_set:        vk.DescriptorSet,
	node_data_descriptor_set:       vk.DescriptorSet,
	mesh_data_descriptor_set:       vk.DescriptorSet,
	vertex_skinning_descriptor_set: vk.DescriptorSet,
	sprite_buffer_descriptor_set:   vk.DescriptorSet,
	lights_descriptor_set:          vk.DescriptorSet,

	// Global buffers (same for all render calls)
	vertex_buffer: vk.Buffer,
	index_buffer:  vk.Buffer,
}
