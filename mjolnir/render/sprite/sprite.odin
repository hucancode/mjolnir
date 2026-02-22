package sprite

import "../../geometry"
import "../../gpu"
import "../camera"
import rctx "../context"
import d "../data"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../shader/sprite/vert.spv")
SHADER_FRAG :: #load("../../shader/sprite/frag.spv")

PushConstant :: struct {
	camera_index: u32,
}

Renderer :: struct {
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
}

init :: proc(
	self: ^Renderer,
	gctx: ^gpu.GPUContext,
	camera_set_layout: vk.DescriptorSetLayout,
	textures_set_layout: vk.DescriptorSetLayout,
	node_data_set_layout: vk.DescriptorSetLayout,
	sprite_set_layout: vk.DescriptorSetLayout,
) -> (
	ret: vk.Result,
) {
	log.info("Initializing sprite renderer")
	self.pipeline_layout = gpu.create_pipeline_layout(
		gctx,
		vk.PushConstantRange {
			stageFlags = {.VERTEX, .FRAGMENT},
			size = size_of(u32),
		},
		camera_set_layout,
		textures_set_layout,
		node_data_set_layout,
		sprite_set_layout,
	) or_return
	defer if ret != .SUCCESS {
		vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
	}

	vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
	defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
	frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
	defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
		pVertexBindingDescriptions      = raw_data(geometry.VERTEX_BINDING_DESCRIPTION[:]),
		vertexAttributeDescriptionCount = len(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS),
		pVertexAttributeDescriptions    = raw_data(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:]),
	}
	shader_stages := gpu.create_vert_frag_stages(vert_module, frag_module)
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(shader_stages),
		pStages             = raw_data(shader_stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
		pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
		pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
		pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
		pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
		pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
		pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
		layout              = self.pipeline_layout,
		pNext               = &gpu.STANDARD_RENDERING_INFO,
	}
	vk.CreateGraphicsPipelines(
		gctx.device,
		0,
		1,
		&pipeline_info,
		nil,
		&self.pipeline,
	) or_return
	defer if ret != .SUCCESS {
		vk.DestroyPipeline(gctx.device, self.pipeline, nil)
	}
	log.info("Sprite pipeline initialized successfully")
	return .SUCCESS
}

destroy :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
	vk.DestroyPipeline(gctx.device, self.pipeline, nil)
	self.pipeline = 0
	vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
	self.pipeline_layout = 0
}

begin_pass :: proc(
	camera: ^camera.CameraResources,
	texture_manager: ^gpu.TextureManager,
	command_buffer: vk.CommandBuffer,
	frame_index: u32,
) {
	color_texture := gpu.get_texture_2d(texture_manager, camera.attachments[.FINAL_IMAGE][frame_index])
	depth_texture := gpu.get_texture_2d(texture_manager, camera.attachments[.DEPTH][frame_index])
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
	ctx: ^rctx.RenderContext,
	cmd: vk.CommandBuffer,
	camera_index: u32,
	draw_commands: vk.Buffer,
	draw_count: vk.Buffer,
) {
	gpu.bind_graphics_pipeline(
		cmd,
		self.pipeline,
		self.pipeline_layout,
		ctx.cameras_descriptor_set,
		ctx.textures_descriptor_set,
		ctx.node_data_descriptor_set,
		ctx.sprite_buffer_descriptor_set,
	)

	push_constants := PushConstant{camera_index = camera_index}
	vk.CmdPushConstants(
		cmd,
		self.pipeline_layout,
		{.VERTEX, .FRAGMENT},
		0,
		size_of(PushConstant),
		&push_constants,
	)
	vertex_buffers := [?]vk.Buffer{ctx.vertex_buffer}
	vertex_offsets := [?]vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, raw_data(vertex_buffers[:]), raw_data(vertex_offsets[:]))
	vk.CmdBindIndexBuffer(cmd, ctx.index_buffer, 0, .UINT32)
	vk.CmdDrawIndexedIndirectCount(
		cmd,
		draw_commands,
		0,
		draw_count,
		0,
		d.MAX_NODES_IN_SCENE,
		u32(size_of(vk.DrawIndexedIndirectCommand)),
	)
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
	vk.CmdEndRendering(command_buffer)
}
