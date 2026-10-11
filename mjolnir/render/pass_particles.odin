#+private
package render

import "gpu"
import "core:log"
import vk "vendor:vulkan"

SHADER_PARTICLE_VERT := #load("shader/particle/vert.spv")
SHADER_PARTICLE_FRAG := #load("shader/particle/frag.spv")

particles_create_render_pipeline :: proc(
	gctx: ^gpu.GPUContext,
	self: ^ParticlesRenderer,
	camera_set_layout: vk.DescriptorSetLayout,
	textures_set_layout: vk.DescriptorSetLayout,
) -> (
	ret: vk.Result,
) {
	self.render_pipeline_layout = gpu.create_pipeline_layout(
		gctx,
		vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(u32)},
		camera_set_layout,
		textures_set_layout,
		self.descriptor_set_layout,
	) or_return
	color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
	blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ALPHA}
	self.render_pipeline = gpu.create_graphics_pipeline(
		gctx,
		{
			vert = SHADER_PARTICLE_VERT,
			frag = SHADER_PARTICLE_FRAG,
			specialization = &SHADER_SPEC_CONSTANTS,
			topology = .POINT_LIST,
			raster = gpu.DOUBLE_SIDED_RASTERIZER,
			depth = gpu.READ_ONLY_DEPTH_STATE,
			blend = blend[:],
			color_formats = color_formats[:],
			depth_format = .D32_SFLOAT,
			layout = self.render_pipeline_layout,
		},
	) or_return
	return .SUCCESS
}

// particles_record draws particles into the camera's color/depth attachments. Owns its
// own begin_rendering / end_rendering scope.
particles_record :: proc(r: ^Manager, frame_index: u32, cam_index: u32, cam: ^Camera) {
	self := &r.internal.particles
	command_buffer := r.internal.command_buffers[frame_index]
	color_texture := camera_image(r, cam, .FINAL_IMAGE, frame_index)
	depth_texture := camera_image(r, cam, .DEPTH, frame_index)
	if color_texture == nil || depth_texture == nil {
		log.error("Particle renderer missing camera attachments")
		return
	}
	// The simulation wrote the particles drawn here at the end of the previous
	// frame. The lighting pass wrote the color image just before.
	gpu.memory_barrier(
		command_buffer,
		{.SHADER_WRITE, .COLOR_ATTACHMENT_WRITE},
		{.SHADER_READ, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
		{.COMPUTE_SHADER, .COLOR_ATTACHMENT_OUTPUT},
		{.VERTEX_SHADER, .COLOR_ATTACHMENT_OUTPUT},
	)
	gpu.begin_rendering(
		command_buffer,
		depth_texture.extent,
		gpu.create_depth_attachment(
			depth_texture.view,
			.LOAD,
			.STORE,
		),
		gpu.create_color_attachment(color_texture.view, .LOAD, .STORE),
	)
	gpu.set_viewport_scissor(command_buffer, depth_texture.extent)
	gpu.bind_pipeline(
		command_buffer,
		.GRAPHICS,
		self.render_pipeline,
		self.render_pipeline_layout,
		r.internal.camera_buffer.descriptor_sets[frame_index],
		r.texture_manager.descriptor_set,
		self.descriptor_set,
	)
	camera_idx := cam_index
	vk.CmdPushConstants(
		command_buffer,
		self.render_pipeline_layout,
		{.VERTEX},
		0,
		size_of(u32),
		&camera_idx,
	)
	vk.CmdDraw(command_buffer, MAX_PARTICLES, 1, 0, 0)
	vk.CmdEndRendering(command_buffer)
	// ...and rewrites them later in this frame.
	gpu.memory_barrier(
		command_buffer,
		{},
		{},
		{.VERTEX_SHADER},
		{.COMPUTE_SHADER},
	)
}
