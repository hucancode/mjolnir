package tonemap

import "../../../gpu"
import "../../camera"
import rg "../../graph"
import "../../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../../shader/postprocess/vert.spv")
SHADER_FRAG :: #load("../../../shader/tonemap/frag.spv")

// Effect configuration
Config :: struct {
	exposure: f32,
	gamma:    f32,
}

// Effect-specific renderer (owns only this effect's pipeline)
Renderer :: struct {
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
}

// Push constant structure - must match shader layout exactly
PushConstant :: struct {
	position_texture_index: u32,
	normal_texture_index:   u32,
	albedo_texture_index:   u32,
	metallic_texture_index: u32,
	emissive_texture_index: u32,
	depth_texture_index:    u32,
	input_image_index:      u32,
	padding:                u32,  // Align to 16-byte boundary
	exposure:               f32,
	gamma:                  f32,
}

// Pass context
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

// Initialize renderer and create pipeline
init :: proc(
	self: ^Renderer,
	gctx: ^gpu.GPUContext,
	textures_set_layout: vk.DescriptorSetLayout,
) -> vk.Result {
	log.info("Initializing tonemap effect pipeline...")

	// Create shader modules
	vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
	defer vk.DestroyShaderModule(gctx.device, vert_module, nil)

	frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
	defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

	shader_stages := gpu.create_vert_frag_stages(
		vert_module,
		frag_module,
		&shared.SHADER_SPEC_CONSTANTS,
	)

	// Create pipeline layout with push constants
	self.pipeline_layout = gpu.create_pipeline_layout(
		gctx,
		vk.PushConstantRange {
			stageFlags = {.FRAGMENT},
			size       = size_of(PushConstant),
		},
		textures_set_layout,
	) or_return

	// Create graphics pipeline
	color_formats := [?]vk.Format{.B8G8R8A8_SRGB}
	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = len(color_formats),
		pColorAttachmentFormats = raw_data(&color_formats),
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info,
		stageCount          = len(shader_stages),
		pStages             = raw_data(&shader_stages),
		pVertexInputState   = &gpu.VERTEX_INPUT_NONE,
		pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
		pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
		pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
		pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
		pColorBlendState    = &gpu.COLOR_BLENDING_OVERRIDE,
		pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
		layout              = self.pipeline_layout,
	}

	vk.CreateGraphicsPipelines(
		gctx.device,
		0,
		1,
		&pipeline_info,
		nil,
		&self.pipeline,
	) or_return

	log.info("Tonemap effect pipeline initialized successfully")
	return .SUCCESS
}

// Destroy renderer and clean up resources
destroy :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
	vk.DestroyPipeline(gctx.device, self.pipeline, nil)
	self.pipeline = 0
	vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
	self.pipeline_layout = 0
}

// Add tonemap node to render graph
add_node :: proc(
	g: ^rg.Graph,
	renderer: ^Renderer,
	texture_manager: ^gpu.TextureManager,
	cam_res: ^camera.CameraResources,
	input_res: rg.ResourceId,
	extent: vk.Extent2D,
	frame_index: u32,
	config: Config,
	is_final_output: bool,
	swapchain_res: rg.ResourceId,
	swapchain_view: vk.ImageView,
	ctx_storage: ^PassCtx,
) -> rg.ResourceId {
	// Create output resource (transient or swapchain)
	output_res := swapchain_res if is_final_output else rg.add_transient_color_texture(
		g,
		"tonemap_output",
		.B8G8R8A8_SRGB,
		extent,
		{.COLOR_ATTACHMENT, .SAMPLED},
	)

	// Initialize pass context
	ctx_storage^ = PassCtx {
		renderer            = renderer,
		texture_manager     = texture_manager,
		graph               = g,
		cam_res             = cam_res,
		frame_index         = frame_index,
		extent              = extent,
		config              = config,
		input_res           = input_res,
		output_res          = output_res,
		is_swapchain_output = is_final_output,
		swapchain_view      = swapchain_view,
	}

	// Register pass with graph
	pass := rg.add_pass(g, "tonemap", pass_execute, ctx_storage)
	rg.pass_read(g, pass, input_res)
	rg.pass_write(g, pass, output_res, .CLEAR)

	return output_res
}

// Pass execute callback (internal)
@(private)
pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^PassCtx)user_data

	// Resolve input texture (use ALBEDO for testing as per original code)
	input_texture := ctx.cam_res.attachments[.ALBEDO][frame_index]

	// Resolve output view
	output_view: vk.ImageView
	if ctx.is_swapchain_output {
		output_view = ctx.swapchain_view
	} else {
		// Try transient textures
		tex_handle, has_tex := ctx.graph.transient_textures[ctx.output_res]
		if !has_tex {
			log.warnf("Tonemap: Failed to resolve output texture from transient_textures")
			return
		}
		output_tex := gpu.get_texture_2d(ctx.texture_manager, tex_handle)
		if output_tex == nil {
			log.warnf("Tonemap: get_texture_2d returned nil")
			return
		}
		output_view = output_tex.view
	}

	// Begin rendering
	color_attachment := gpu.create_color_attachment_view(output_view, .CLEAR, .STORE)
	gpu.begin_rendering(cmd, ctx.extent, nil, color_attachment)
	gpu.set_viewport_scissor(cmd, ctx.extent)

	// Bind pipeline
	gpu.bind_graphics_pipeline(
		cmd,
		ctx.renderer.pipeline,
		ctx.renderer.pipeline_layout,
		ctx.texture_manager.descriptor_set,
	)

	// Push constants - fill all fields to match shader layout
	push := PushConstant {
		position_texture_index = 0,  // Unused for tonemap
		normal_texture_index   = 0,  // Unused for tonemap
		albedo_texture_index   = 0,  // Unused for tonemap
		metallic_texture_index = 0,  // Unused for tonemap
		emissive_texture_index = 0,  // Unused for tonemap
		depth_texture_index    = 0,  // Unused for tonemap
		input_image_index      = input_texture.index,
		padding                = 0,
		exposure               = ctx.config.exposure,
		gamma                  = ctx.config.gamma,
	}
	vk.CmdPushConstants(
		cmd,
		ctx.renderer.pipeline_layout,
		{.FRAGMENT},
		0,
		size_of(PushConstant),
		&push,
	)

	// Draw fullscreen triangle
	vk.CmdDraw(cmd, 3, 1, 0, 0)

	// End rendering
	vk.CmdEndRendering(cmd)
}
