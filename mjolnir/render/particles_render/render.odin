package particles_render

import "../../gpu"
import "../camera"
import "../shared"
import rg "../graph"
import "core:log"
import "core:fmt"
import vk "vendor:vulkan"

SHADER_PARTICLE_VERT := #load("../../shader/particle/vert.spv")
SHADER_PARTICLE_FRAG := #load("../../shader/particle/frag.spv")
TEXTURE_BLACK_CIRCLE :: #load("../../assets/black-circle.png")

Particle :: struct {
	position:      [3]f32,
	size:          f32,
	velocity:      [3]f32,
	size_end:      f32,
	color_start:   [4]f32,
	color_end:     [4]f32,
	color:         [4]f32,
	life:          f32,
	max_life:      f32,
	weight:        f32,
	texture_index: u32,
}

Renderer :: struct {
	render_pipeline_layout: vk.PipelineLayout,
	render_pipeline:        vk.Pipeline,
	default_texture_index:  u32,
}

init :: proc(
	self: ^Renderer,
	gctx: ^gpu.GPUContext,
	texture_manager: ^gpu.TextureManager,
	camera_set_layout: vk.DescriptorSetLayout,
	textures_set_layout: vk.DescriptorSetLayout,
) -> (
	ret: vk.Result,
) {
	log.debugf("Initializing particle render renderer")

	default_texture_handle := gpu.create_texture_2d_from_data(
		gctx,
		texture_manager,
		TEXTURE_BLACK_CIRCLE,
	) or_return
	defer if ret != .SUCCESS {
		gpu.free_texture_2d(texture_manager, gctx, default_texture_handle)
	}
	self.default_texture_index = default_texture_handle.index

	create_render_pipeline(gctx, self, camera_set_layout, textures_set_layout) or_return
	defer if ret != .SUCCESS {
		vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
		vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
	}

	return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
	vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
	vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
}

create_render_pipeline :: proc(
	gctx: ^gpu.GPUContext,
	self: ^Renderer,
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
	) or_return
	defer if ret != .SUCCESS {
		vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
	}

	vertex_binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(Particle),
		inputRate = .VERTEX,
	}

	vertex_attributes := [?]vk.VertexInputAttributeDescription {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Particle, position)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Particle, color)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Particle, size)),
		},
		{
			location = 3,
			binding = 0,
			format = .R32_UINT,
			offset = u32(offset_of(Particle, texture_index)),
		},
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &vertex_binding,
		vertexAttributeDescriptionCount = len(vertex_attributes),
		pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
	}

	vert_module := gpu.create_shader_module(gctx.device, SHADER_PARTICLE_VERT) or_return
	frag_module := gpu.create_shader_module(gctx.device, SHADER_PARTICLE_FRAG) or_return
	defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
	defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

	shader_stages := gpu.create_vert_frag_stages(
		vert_module,
		frag_module,
		&shared.SHADER_SPEC_CONSTANTS,
	)

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(shader_stages),
		pStages             = raw_data(shader_stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &gpu.POINT_INPUT_ASSEMBLY,
		pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
		pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
		pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
		pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
		pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
		pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
		layout              = self.render_pipeline_layout,
		pNext               = &gpu.STANDARD_RENDERING_INFO,
	}

	vk.CreateGraphicsPipelines(
		gctx.device,
		0,
		1,
		&pipeline_info,
		nil,
		&self.render_pipeline,
	) or_return

	return .SUCCESS
}

begin_pass :: proc(
	self: ^Renderer,
	command_buffer: vk.CommandBuffer,
	camera: ^camera.Camera,
	texture_manager: ^gpu.TextureManager,
	frame_index: u32,
) {
	color_texture := gpu.get_texture_2d(
		texture_manager,
		camera.attachments[.FINAL_IMAGE][frame_index],
	)
	if color_texture == nil {
		log.error("Particle renderer missing color attachment")
		return
	}

	depth_texture := gpu.get_texture_2d(
		texture_manager,
		camera.attachments[.DEPTH][frame_index],
	)
	if depth_texture == nil {
		log.error("Particle renderer missing depth attachment")
		return
	}

	gpu.begin_rendering(
		command_buffer,
		depth_texture.spec.extent,
		gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
		gpu.create_color_attachment(color_texture, .LOAD, .STORE),
	)

	gpu.set_viewport_scissor(command_buffer, depth_texture.spec.extent)
}

render :: proc(
	self: ^Renderer,
	command_buffer: vk.CommandBuffer,
	camera_index: u32,
	cameras_descriptor_set: vk.DescriptorSet,
	textures_descriptor_set: vk.DescriptorSet,
	compact_particle_buffer: vk.Buffer,
	draw_command_buffer: vk.Buffer,
) {
	gpu.bind_graphics_pipeline(
		command_buffer,
		self.render_pipeline,
		self.render_pipeline_layout,
		cameras_descriptor_set,
		textures_descriptor_set,
	)

	camera_idx := camera_index
	vk.CmdPushConstants(
		command_buffer,
		self.render_pipeline_layout,
		{.VERTEX},
		0,
		size_of(u32),
		&camera_idx,
	)

	offset: vk.DeviceSize = 0
	buffer := compact_particle_buffer
	vk.CmdBindVertexBuffers(
		command_buffer,
		0,
		1,
		&buffer,
		&offset,
	)

	vk.CmdDrawIndirect(
		command_buffer,
		draw_command_buffer,
		0,
		1,
		size_of(vk.DrawIndirectCommand),
	)
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
	vk.CmdEndRendering(command_buffer)
}

// ====== GRAPH-BASED API ======

// Context for graph-based particle rendering
// Contains renderer + necessary descriptor sets
ParticleRenderGraphContext :: struct {
	renderer: ^Renderer,
	camera_descriptor_set: vk.DescriptorSet,
	textures_descriptor_set: vk.DescriptorSet,
}

// Setup phase: declare resource dependencies
particles_render_setup :: proc(builder: ^rg.PassBuilder, user_data: rawptr) {
	// Read compact particle buffer (written by particle compute pass)
	rg.builder_read(builder, "compact_particle_buffer")

	// Read draw command buffer (written by particle compute pass)
	rg.builder_read(builder, "draw_command_buffer")

	// Read/Write camera attachments (per-camera scoped)
	cam_idx := builder.scope_index

	// Read depth for depth testing
	rg.builder_read(builder, fmt.tprintf("camera_%d_depth", cam_idx))

	// Write to final image (additive blending)
	rg.builder_write(builder, fmt.tprintf("camera_%d_final_image", cam_idx))
}

// Execute phase: render with resolved resources
particles_render_execute :: proc(ctx: ^rg.PassContext, user_data: rawptr) {
	pass_ctx := cast(^ParticleRenderGraphContext)user_data
	self := pass_ctx.renderer
	cam_idx := ctx.scope_index

	// Resolve compact particle buffer
	compact_buf_id, ok1 := ctx.graph.resource_ids["compact_particle_buffer"]
	if !ok1 {
		log.error("Failed to find compact_particle_buffer resource")
		return
	}
	compact_buf_handle, resolve_ok1 := rg.resolve(rg.BufferHandle, ctx, ctx.exec_ctx, compact_buf_id)
	if !resolve_ok1 {
		log.error("Failed to resolve compact_particle_buffer")
		return
	}

	// Resolve draw command buffer
	draw_cmd_id, ok2 := ctx.graph.resource_ids["draw_command_buffer"]
	if !ok2 {
		log.error("Failed to find draw_command_buffer resource")
		return
	}
	draw_cmd_handle, resolve_ok2 := rg.resolve(rg.BufferHandle, ctx, ctx.exec_ctx, draw_cmd_id)
	if !resolve_ok2 {
		log.error("Failed to resolve draw_command_buffer")
		return
	}

	// Resolve camera depth
	depth_name := fmt.tprintf("camera_%d_depth", cam_idx)
	depth_id, ok3 := ctx.graph.resource_ids[depth_name]
	if !ok3 {
		log.errorf("Failed to find camera depth resource: %s", depth_name)
		return
	}
	depth_handle, resolve_ok3 := rg.resolve(rg.DepthTextureHandle, ctx, ctx.exec_ctx, depth_id)
	if !resolve_ok3 {
		log.error("Failed to resolve camera depth")
		return
	}

	// Resolve camera final image
	final_image_name := fmt.tprintf("camera_%d_final_image", cam_idx)
	final_image_id, ok4 := ctx.graph.resource_ids[final_image_name]
	if !ok4 {
		log.errorf("Failed to find camera final_image resource: %s", final_image_name)
		return
	}
	final_image_handle, resolve_ok4 := rg.resolve(rg.TextureHandle, ctx, ctx.exec_ctx, final_image_id)
	if !resolve_ok4 {
		log.error("Failed to resolve camera final_image")
		return
	}

	// Begin rendering
	depth_attachment := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = depth_handle.view,
		imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
		loadOp = .LOAD,
		storeOp = .STORE,
	}

	color_attachment := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = final_image_handle.view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .LOAD,
		storeOp = .STORE,
	}

	rendering_info := vk.RenderingInfo{
		sType = .RENDERING_INFO,
		renderArea = {extent = {final_image_handle.extent.width, final_image_handle.extent.height}},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
		pDepthAttachment = &depth_attachment,
	}

	vk.CmdBeginRendering(ctx.cmd, &rendering_info)

	// Set viewport and scissor
	gpu.set_viewport_scissor(ctx.cmd, final_image_handle.extent)

	// Bind pipeline and descriptor sets
	gpu.bind_graphics_pipeline(
		ctx.cmd,
		self.render_pipeline,
		self.render_pipeline_layout,
		pass_ctx.camera_descriptor_set,
		pass_ctx.textures_descriptor_set,
	)

	// Push camera index constant
	camera_idx_push := cam_idx
	vk.CmdPushConstants(
		ctx.cmd,
		self.render_pipeline_layout,
		{.VERTEX},
		0,
		size_of(u32),
		&camera_idx_push,
	)

	// Bind vertex buffer (compact particle buffer)
	offset: vk.DeviceSize = 0
	vk.CmdBindVertexBuffers(
		ctx.cmd,
		0,
		1,
		&compact_buf_handle.buffer,
		&offset,
	)

	// Draw indirect
	vk.CmdDrawIndirect(
		ctx.cmd,
		draw_cmd_handle.buffer,
		0,
		1,
		size_of(vk.DrawIndirectCommand),
	)

	vk.CmdEndRendering(ctx.cmd)
}
