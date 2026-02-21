package crosshatch

import "../../../gpu"
import "../../camera"
import rg "../../graph"
import "../../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../../shader/postprocess/vert.spv")
SHADER_FRAG :: #load("../../../shader/crosshatch/frag.spv")

Config :: struct {
	resolution:       [2]f32,
	hatch_offset_y:   f32,
	lum_threshold_01: f32,
	lum_threshold_02: f32,
	lum_threshold_03: f32,
	lum_threshold_04: f32,
}

Renderer :: struct {
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
}

PushConstant :: struct {
	input_image_index: u32,
	resolution:        [2]f32,
	hatch_offset_y:    f32,
	lum_threshold_01:  f32,
	lum_threshold_02:  f32,
	lum_threshold_03:  f32,
	lum_threshold_04:  f32,
}

PassCtx :: struct {
	renderer:            ^Renderer,
	texture_manager:     ^gpu.TextureManager,
	graph:               ^rg.Graph,
	cam_res:             ^camera.CameraResources,
	frame_index:         u32,
	extent:              vk.Extent2D,
	config:              Config,
	input_res:           rg.ResourceId,
	output_res:          rg.ResourceId,
	is_swapchain_output: bool,
	swapchain_view:      vk.ImageView,
}

init :: proc(self: ^Renderer, gctx: ^gpu.GPUContext, textures_set_layout: vk.DescriptorSetLayout) -> vk.Result {
	log.info("Initializing crosshatch effect pipeline...")

	vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
	defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
	frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
	defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

	shader_stages := gpu.create_vert_frag_stages(vert_module, frag_module, &shared.SHADER_SPEC_CONSTANTS)
	self.pipeline_layout = gpu.create_pipeline_layout(gctx, vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = size_of(PushConstant)}, textures_set_layout) or_return

	color_formats := [?]vk.Format{.B8G8R8A8_SRGB}
	rendering_info := vk.PipelineRenderingCreateInfo{sType = .PIPELINE_RENDERING_CREATE_INFO, colorAttachmentCount = len(color_formats), pColorAttachmentFormats = raw_data(&color_formats)}
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO, pNext = &rendering_info, stageCount = len(shader_stages), pStages = raw_data(&shader_stages),
		pVertexInputState = &gpu.VERTEX_INPUT_NONE, pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY, pViewportState = &gpu.STANDARD_VIEWPORT_STATE,
		pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER, pMultisampleState = &gpu.STANDARD_MULTISAMPLING, pColorBlendState = &gpu.COLOR_BLENDING_OVERRIDE,
		pDynamicState = &gpu.STANDARD_DYNAMIC_STATES, layout = self.pipeline_layout,
	}

	vk.CreateGraphicsPipelines(gctx.device, 0, 1, &pipeline_info, nil, &self.pipeline) or_return
	log.info("Crosshatch effect pipeline initialized successfully")
	return .SUCCESS
}

destroy :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
	vk.DestroyPipeline(gctx.device, self.pipeline, nil)
	self.pipeline = 0
	vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
	self.pipeline_layout = 0
}

add_node :: proc(g: ^rg.Graph, renderer: ^Renderer, texture_manager: ^gpu.TextureManager, cam_res: ^camera.CameraResources, input_res: rg.ResourceId, extent: vk.Extent2D, frame_index: u32, config: Config, is_final_output: bool, swapchain_res: rg.ResourceId, swapchain_view: vk.ImageView, ctx_storage: ^PassCtx) -> rg.ResourceId {
	output_res := swapchain_res if is_final_output else rg.add_transient_color_texture(g, "crosshatch_output", .B8G8R8A8_SRGB, extent, {.COLOR_ATTACHMENT, .SAMPLED})
	ctx_storage^ = PassCtx{renderer = renderer, texture_manager = texture_manager, graph = g, cam_res = cam_res, frame_index = frame_index, extent = extent, config = config, input_res = input_res, output_res = output_res, is_swapchain_output = is_final_output, swapchain_view = swapchain_view}
	pass := rg.add_pass(g, "crosshatch", pass_execute, ctx_storage)
	rg.pass_read(g, pass, input_res)
	rg.pass_write(g, pass, output_res, .CLEAR)
	return output_res
}

@(private)
pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^PassCtx)user_data
	input_texture := ctx.cam_res.attachments[.FINAL_IMAGE][frame_index]

	output_view: vk.ImageView
	if ctx.is_swapchain_output {
		output_view = ctx.swapchain_view
	} else {
		tex_handle, has_tex := ctx.graph.transient_textures[ctx.output_res]
		if !has_tex do return
		output_tex := gpu.get_texture_2d(ctx.texture_manager, tex_handle)
		if output_tex == nil do return
		output_view = output_tex.view
	}

	color_attachment := gpu.create_color_attachment_view(output_view, .CLEAR, .STORE)
	gpu.begin_rendering(cmd, ctx.extent, nil, color_attachment)
	gpu.set_viewport_scissor(cmd, ctx.extent)
	gpu.bind_graphics_pipeline(cmd, ctx.renderer.pipeline, ctx.renderer.pipeline_layout, ctx.texture_manager.descriptor_set)

	push := PushConstant {
		input_image_index = input_texture.index,
		resolution        = ctx.config.resolution,
		hatch_offset_y    = ctx.config.hatch_offset_y,
		lum_threshold_01  = ctx.config.lum_threshold_01,
		lum_threshold_02  = ctx.config.lum_threshold_02,
		lum_threshold_03  = ctx.config.lum_threshold_03,
		lum_threshold_04  = ctx.config.lum_threshold_04,
	}
	vk.CmdPushConstants(cmd, ctx.renderer.pipeline_layout, {.FRAGMENT}, 0, size_of(PushConstant), &push)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
	vk.CmdEndRendering(cmd)
}
