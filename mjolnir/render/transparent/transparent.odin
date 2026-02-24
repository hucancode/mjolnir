package transparent

import "../../geometry"
import "../../gpu"
import "../camera"
import d "../data"
import rg "../graph"
import "../wireframe"
import "../random_color"
import "../line_strip"
import "../sprite"
import "core:fmt"
import vk "vendor:vulkan"

SHADER_TRANSPARENT_VERT :: #load("../../shader/transparent/vert.spv")
SHADER_TRANSPARENT_FRAG :: #load("../../shader/transparent/frag.spv")

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
	vert_module := gpu.create_shader_module(gctx.device, SHADER_TRANSPARENT_VERT) or_return
	defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
	frag_module := gpu.create_shader_module(gctx.device, SHADER_TRANSPARENT_FRAG) or_return
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

destroy :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
	vk.DestroyPipeline(gctx.device, self.pipeline, nil)
	self.pipeline = 0
	vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
	self.pipeline_layout = 0
}

render :: proc(
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
	draw_buffer: vk.Buffer,
	count_buffer: vk.Buffer,
	max_draw_count: u32,
) {
	// Bind pipeline
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

	// Push constants
	push_constants := PushConstant{camera_index = camera_index}
	vk.CmdPushConstants(
		cmd,
		self.pipeline_layout,
		{.VERTEX, .FRAGMENT},
		0,
		size_of(PushConstant),
		&push_constants,
	)

	// Bind vertex/index buffers
	vertex_buffers := [?]vk.Buffer{vertex_buffer}
	vertex_offsets := [?]vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, raw_data(vertex_buffers[:]), raw_data(vertex_offsets[:]))
	vk.CmdBindIndexBuffer(cmd, index_buffer, 0, .UINT32)

	// Draw
	vk.CmdDrawIndexedIndirectCount(
		cmd,
		draw_buffer,
		0,
		count_buffer,
		0,
		max_draw_count,
		u32(size_of(vk.DrawIndexedIndirectCommand)),
	)
}

// ============================================================================
// Graph-based API for render graph integration
// ============================================================================

// Context for transparency rendering pass (used by all 5 transparency techniques)
TransparencyRenderingPassGraphContext :: struct {
	// Renderers for all 5 techniques
	transparent_renderer:    ^Renderer,
	wireframe_renderer:      ^wireframe.Renderer,
	random_color_renderer:   ^random_color.Renderer,
	line_strip_renderer:     ^line_strip.Renderer,
	sprite_renderer:         ^sprite.Renderer,

	// Shared resources
	texture_manager:         ^gpu.TextureManager,
	cameras_descriptor_set:  vk.DescriptorSet,
	textures_descriptor_set: vk.DescriptorSet,
	bone_descriptor_set:     vk.DescriptorSet,
	material_descriptor_set: vk.DescriptorSet,
	node_data_descriptor_set: vk.DescriptorSet,
	mesh_data_descriptor_set: vk.DescriptorSet,
	vertex_skinning_descriptor_set: vk.DescriptorSet,
	sprite_descriptor_set:   vk.DescriptorSet,
	vertex_buffer:           vk.Buffer,
	index_buffer:            vk.Buffer,
	cameras:                 ^map[u32]camera.Camera,
}

// Setup phase: declare dependencies for transparency rendering
transparency_rendering_pass_setup :: proc(builder: ^rg.PassBuilder, user_data: rawptr) {
	cam_index := builder.scope_index

	// Read depth (for depth testing)
	rg.builder_read(builder, fmt.tprintf("camera_%d_depth", cam_index))

	// Read all 5 transparency draw command/count buffers (written by culling pass)
	rg.builder_read(builder, fmt.tprintf("camera_%d_transparent_draw_commands", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_transparent_draw_count", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_wireframe_draw_commands", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_wireframe_draw_count", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_random_color_draw_commands", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_random_color_draw_count", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_line_strip_draw_commands", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_line_strip_draw_count", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_sprite_draw_commands", cam_index))
	rg.builder_read(builder, fmt.tprintf("camera_%d_sprite_draw_count", cam_index))

	// Read-write final_image (blend transparency with existing lighting)
	rg.builder_read_write(builder, fmt.tprintf("camera_%d_final_image", cam_index))
}

// Execute phase: render all transparency techniques
transparency_rendering_pass_execute :: proc(pass_ctx: ^rg.PassContext, user_data: rawptr) {
	ctx := cast(^TransparencyRenderingPassGraphContext)user_data
	cmd := pass_ctx.cmd
	cam_idx := pass_ctx.scope_index
	cam, cam_ok := ctx.cameras[cam_idx]
	if !cam_ok do return

	// Resolve final_image and depth resources
	final_image_name := fmt.tprintf("camera_%d_final_image", cam_idx)
	final_image_id := rg.ResourceId(final_image_name)
	if final_image_id not_in pass_ctx.graph.resources do return
	final_image_handle, _ := rg.resolve(rg.TextureHandle, pass_ctx, final_image_id)

	depth_name := fmt.tprintf("camera_%d_depth", cam_idx)
	depth_id := rg.ResourceId(depth_name)
	if depth_id not_in pass_ctx.graph.resources do return
	depth_handle, _ := rg.resolve(rg.DepthTextureHandle, pass_ctx, depth_id)

	// Create rendering attachments with LOAD operations
	color_attachment := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = final_image_handle.view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .LOAD,  // Load existing content (lighting)
		storeOp = .STORE,
	}

	depth_attachment := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = depth_handle.view,
		imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		loadOp = .LOAD,  // Load existing depth
		storeOp = .STORE,
	}

	// Begin rendering (shared by all 5 techniques)
	rendering_info := vk.RenderingInfo{
		sType = .RENDERING_INFO,
		renderArea = {extent = final_image_handle.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
		pDepthAttachment = &depth_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)
	gpu.set_viewport_scissor(cmd, final_image_handle.extent)

	// Render transparent objects (using dedicated transparent buffers)
	render(
		ctx.transparent_renderer,
		cmd,
		cam_idx,
		ctx.cameras_descriptor_set,
		ctx.textures_descriptor_set,
		ctx.bone_descriptor_set,
		ctx.material_descriptor_set,
		ctx.node_data_descriptor_set,
		ctx.mesh_data_descriptor_set,
		ctx.vertex_skinning_descriptor_set,
		ctx.vertex_buffer,
		ctx.index_buffer,
		cam.transparent_draw_commands[pass_ctx.frame_index].buffer,
		cam.transparent_draw_count[pass_ctx.frame_index].buffer,
		d.MAX_NODES_IN_SCENE,
	)

	// Render wireframe objects (using dedicated wireframe buffers)
	wireframe.render(
		ctx.wireframe_renderer,
		cmd,
		cam_idx,
		ctx.cameras_descriptor_set,
		ctx.textures_descriptor_set,
		ctx.bone_descriptor_set,
		ctx.material_descriptor_set,
		ctx.node_data_descriptor_set,
		ctx.mesh_data_descriptor_set,
		ctx.vertex_skinning_descriptor_set,
		ctx.vertex_buffer,
		ctx.index_buffer,
		cam.wireframe_draw_commands[pass_ctx.frame_index].buffer,
		cam.wireframe_draw_count[pass_ctx.frame_index].buffer,
		d.MAX_NODES_IN_SCENE,
	)

	// Render random_color objects (using dedicated random_color buffers)
	random_color.render(
		ctx.random_color_renderer,
		cmd,
		cam_idx,
		ctx.cameras_descriptor_set,
		ctx.textures_descriptor_set,
		ctx.bone_descriptor_set,
		ctx.material_descriptor_set,
		ctx.node_data_descriptor_set,
		ctx.mesh_data_descriptor_set,
		ctx.vertex_skinning_descriptor_set,
		ctx.vertex_buffer,
		ctx.index_buffer,
		cam.random_color_draw_commands[pass_ctx.frame_index].buffer,
		cam.random_color_draw_count[pass_ctx.frame_index].buffer,
		d.MAX_NODES_IN_SCENE,
	)

	// Render line_strip objects (using dedicated line_strip buffers)
	line_strip.render(
		ctx.line_strip_renderer,
		cmd,
		cam_idx,
		ctx.cameras_descriptor_set,
		ctx.textures_descriptor_set,
		ctx.bone_descriptor_set,
		ctx.material_descriptor_set,
		ctx.node_data_descriptor_set,
		ctx.mesh_data_descriptor_set,
		ctx.vertex_skinning_descriptor_set,
		ctx.vertex_buffer,
		ctx.index_buffer,
		cam.line_strip_draw_commands[pass_ctx.frame_index].buffer,
		cam.line_strip_draw_count[pass_ctx.frame_index].buffer,
		d.MAX_NODES_IN_SCENE,
	)

	// Render sprite objects (using dedicated sprite buffers, different descriptor sets)
	sprite.render(
		ctx.sprite_renderer,
		cmd,
		cam_idx,
		ctx.cameras_descriptor_set,
		ctx.textures_descriptor_set,
		ctx.node_data_descriptor_set,
		ctx.sprite_descriptor_set,
		ctx.vertex_buffer,
		ctx.index_buffer,
		cam.sprite_draw_commands[pass_ctx.frame_index].buffer,
		cam.sprite_draw_count[pass_ctx.frame_index].buffer,
		d.MAX_NODES_IN_SCENE,
	)

	vk.CmdEndRendering(cmd)
}
