package random_color

import "../../geometry"
import "../../gpu"
import vk "vendor:vulkan"

SHADER_RANDOM_COLOR_VERT :: #load("../../shader/random_color/vert.spv")
SHADER_RANDOM_COLOR_FRAG :: #load("../../shader/random_color/frag.spv")

Renderer :: struct {
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
}

PushConstant :: struct {
	camera_index: u32,
}

init :: proc(
	self: ^Renderer,
	gctx: ^gpu.GPUContext,
	camera_set_layout: vk.DescriptorSetLayout,
	textures_set_layout: vk.DescriptorSetLayout,
	bone_set_layout: vk.DescriptorSetLayout,
	material_set_layout: vk.DescriptorSetLayout,
	node_data_set_layout: vk.DescriptorSetLayout,
	mesh_data_set_layout: vk.DescriptorSetLayout,
	vertex_skinning_set_layout: vk.DescriptorSetLayout,
) -> vk.Result {
	// Create pipeline layout
	self.pipeline_layout = gpu.create_pipeline_layout(
		gctx,
		vk.PushConstantRange{
			stageFlags = {.VERTEX, .FRAGMENT},
			size = size_of(u32),
		},
		camera_set_layout,
		textures_set_layout,
		bone_set_layout,
		material_set_layout,
		node_data_set_layout,
		mesh_data_set_layout,
		vertex_skinning_set_layout,
	) or_return

	// Create shader modules
	vert_module := gpu.create_shader_module(gctx.device, SHADER_RANDOM_COLOR_VERT) or_return
	defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
	frag_module := gpu.create_shader_module(gctx.device, SHADER_RANDOM_COLOR_FRAG) or_return
	defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

	// Create pipeline
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount = len(geometry.VERTEX_BINDING_DESCRIPTION),
		pVertexBindingDescriptions = raw_data(geometry.VERTEX_BINDING_DESCRIPTION[:]),
		vertexAttributeDescriptionCount = len(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS),
		pVertexAttributeDescriptions = raw_data(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:]),
	}
	shader_stages := gpu.create_vert_frag_stages(vert_module, frag_module)
	pipeline_info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = len(shader_stages),
		pStages = raw_data(shader_stages[:]),
		pVertexInputState = &vertex_input_info,
		pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
		pViewportState = &gpu.STANDARD_VIEWPORT_STATE,
		pRasterizationState = &gpu.STANDARD_RASTERIZER,
		pMultisampleState = &gpu.STANDARD_MULTISAMPLING,
		pDepthStencilState = &gpu.READ_ONLY_DEPTH_STATE,
		pColorBlendState = &gpu.COLOR_BLENDING_ADDITIVE,
		pDynamicState = &gpu.STANDARD_DYNAMIC_STATES,
		layout = self.pipeline_layout,
		pNext = &gpu.STANDARD_RENDERING_INFO,
	}
	vk.CreateGraphicsPipelines(gctx.device, 0, 1, &pipeline_info, nil, &self.pipeline) or_return

	return .SUCCESS
}

setup :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) -> vk.Result {
	return .SUCCESS
}

teardown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
	vk.DestroyPipeline(gctx.device, self.pipeline, nil)
	self.pipeline = 0
	vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
	self.pipeline_layout = 0
}

record :: proc(
	self: ^Renderer,
	cmd: vk.CommandBuffer,
	camera_index: u32,
	camera_set: vk.DescriptorSet,
	textures_set: vk.DescriptorSet,
	bone_set: vk.DescriptorSet,
	material_set: vk.DescriptorSet,
	node_data_set: vk.DescriptorSet,
	mesh_data_set: vk.DescriptorSet,
	vertex_skinning_set: vk.DescriptorSet,
	vertex_buffer: vk.Buffer,
	index_buffer: vk.Buffer,
	draw_buffer: ^gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
	count_buffer: ^gpu.MutableBuffer(u32),
	max_draw_count: u32,
) {
	gpu.buffer_barrier(
		cmd,
		draw_buffer.buffer,
		vk.DeviceSize(draw_buffer.bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	gpu.buffer_barrier(
		cmd,
		count_buffer.buffer,
		vk.DeviceSize(count_buffer.bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	gpu.bind_graphics_pipeline(
		cmd,
		self.pipeline,
		self.pipeline_layout,
		camera_set,
		textures_set,
		bone_set,
		material_set,
		node_data_set,
		mesh_data_set,
		vertex_skinning_set,
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
	vertex_buffers := [?]vk.Buffer{vertex_buffer}
	vertex_offsets := [?]vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, raw_data(vertex_buffers[:]), raw_data(vertex_offsets[:]))
	vk.CmdBindIndexBuffer(cmd, index_buffer, 0, .UINT32)
	vk.CmdDrawIndexedIndirectCount(
		cmd,
		draw_buffer.buffer,
		0,
		count_buffer.buffer,
		0,
		max_draw_count,
		u32(size_of(vk.DrawIndexedIndirectCommand)),
	)
}
