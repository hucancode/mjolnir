// The code here follows the tutorial from:
// https://vulkan-tutorial.com

package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1600
HEIGHT :: 900
TITLE :: "Vulkan"
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)
// KHR_PORTABILITY_SUBSET_EXTENSION_NAME :: "VK_KHR_portability_subset"
REQUIRED_EXTENSIONS :: []cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	// KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
}
when ENABLE_VALIDATION_LAYERS {
	LAYERS :: []cstring{"VK_LAYER_KHRONOS_validation"}
} else {
	LAYERS :: []cstring{}
}
SHADER_VERT :: #load("shaders/vert.spv")
SHADER_FRAG :: #load("shaders/frag.spv")
MAX_FRAMES_IN_FLIGHT :: 2

g_ctx: runtime.Context
g_window: glfw.WindowHandle
g_instance: vk.Instance
g_dbg_messenger: vk.DebugUtilsMessengerEXT

g_physical_device: vk.PhysicalDevice

g_device: vk.Device
g_surface: vk.SurfaceKHR
g_graphics_queue: vk.Queue
g_present_queue: vk.Queue

g_swapchain: vk.SwapchainKHR
g_swapchain_images: []vk.Image
g_swapchain_views: []vk.ImageView
g_swapchain_format: vk.SurfaceFormatKHR
g_swapchain_extent: vk.Extent2D
g_swapchain_frame_buffers: []vk.Framebuffer

g_vert_shader_module: vk.ShaderModule
g_frag_shader_module: vk.ShaderModule
g_shader_stages: [2]vk.PipelineShaderStageCreateInfo
g_render_pass: vk.RenderPass
g_pipeline_layout: vk.PipelineLayout
g_pipeline: vk.Pipeline

g_command_pool: vk.CommandPool
g_command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer

g_image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence

g_current_frame: u32
g_framebuffer_resized: bool

main :: proc() {
	must :: proc(result: vk.Result, loc := #caller_location) {
		if result != .SUCCESS {
			log.panicf("vulkan failure %v", result, location = loc)
		}
	}
	context.logger = log.create_console_logger()
	g_ctx = context
	if !bool(glfw.Init()) {
		log.panic("GLFW has failed to load.")
	}
	defer glfw.Terminate()
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	g_window = glfw.CreateWindow(WIDTH, HEIGHT, TITLE, nil, nil)
	defer glfw.DestroyWindow(g_window)
	if g_window == nil {
		log.panic("GLFW has failed to load the window.")
	}
	glfw.SetFramebufferSizeCallback(g_window, proc "c" (_: glfw.WindowHandle, _, _: i32) {
		g_framebuffer_resized = true
	})
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	must(create_vulkan_instance())
	defer {
		when ENABLE_VALIDATION_LAYERS {
			vk.DestroyDebugUtilsMessengerEXT(g_instance, g_dbg_messenger, nil)
		}
		vk.DestroyInstance(g_instance, nil)
	}

	must(glfw.CreateWindowSurface(g_instance, g_window, nil, &g_surface))
	defer vk.DestroySurfaceKHR(g_instance, g_surface, nil)

	must(pick_physical_device())

	must(create_logical_device())
	defer vk.DestroyDevice(g_device, nil)

	must(create_swapchain())
	defer destroy_swapchain()

	must(load_shader())
	defer {
		vk.DestroyShaderModule(g_device, g_vert_shader_module, nil)
		vk.DestroyShaderModule(g_device, g_frag_shader_module, nil)
	}

	must(create_render_pass())
	defer vk.DestroyRenderPass(g_device, g_render_pass, nil)

	must(create_framebuffers())
	defer destroy_framebuffers()

	must(create_pipeline())
	defer {
		vk.DestroyPipelineLayout(g_device, g_pipeline_layout, nil)
		vk.DestroyPipeline(g_device, g_pipeline, nil)
	}

	must(create_command_pool())

	defer vk.DestroyCommandPool(g_device, g_command_pool, nil)

	must(create_semaphores())
	defer detroy_semaphores()

	for !glfw.WindowShouldClose(g_window) {
		free_all(g_ctx.temp_allocator)
		glfw.PollEvents()
		render()
	}
	vk.DeviceWaitIdle(g_device)
}

// 1. Create a Vulkan instance
create_vulkan_instance :: proc() -> vk.Result {
	log.info("Creating Vulkan instance...")
	extensions := slice.clone_to_dynamic(
		glfw.GetRequiredInstanceExtensions(),
		g_ctx.temp_allocator,
	)
	create_info := vk.InstanceCreateInfo {
		sType               = .INSTANCE_CREATE_INFO,
		pApplicationInfo    = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "Hello VK",
			applicationVersion = vk.MAKE_VERSION(1, 0, 0),
			pEngineName = "Goldfish Engine",
			engineVersion = vk.MAKE_VERSION(1, 0, 0),
			apiVersion = vk.API_VERSION_1_4,
		},
		ppEnabledLayerNames = raw_data(LAYERS),
		enabledLayerCount   = u32(len(LAYERS)),
	}
	when ENABLE_VALIDATION_LAYERS {
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		// Severity based on logger level.
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		if context.logger.lowest_level <= .Info {
			severity |= {.INFO}
		}
		if context.logger.lowest_level <= .Debug {
			severity |= {.VERBOSE}
		}

		dbg_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING}, // all of them.
			pfnUserCallback = proc "system" (
				severity: vk.DebugUtilsMessageSeverityFlagsEXT,
				types: vk.DebugUtilsMessageTypeFlagsEXT,
				pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
				pUserData: rawptr,
			) -> b32 {
				context = g_ctx
				level: log.Level
				if .ERROR in severity {
					level = .Error
				} else if .WARNING in severity {
					level = .Warning
				} else if .INFO in severity {
					level = .Info
				} else {
					level = .Debug
				}
				log.logf(level, "vulkan[%v]: %s", types, pCallbackData.pMessage)
				return false
			},
		}
		create_info.pNext = &dbg_create_info
	}
	create_info.enabledExtensionCount = u32(len(extensions))
	create_info.ppEnabledExtensionNames = raw_data(extensions)
	vk.CreateInstance(&create_info, nil, &g_instance) or_return
	vk.load_proc_addresses_instance(g_instance)
	when ENABLE_VALIDATION_LAYERS {
		vk.CreateDebugUtilsMessengerEXT(
			g_instance,
			&dbg_create_info,
			nil,
			&g_dbg_messenger,
		) or_return
	}
	return .SUCCESS
}

QueueFamilyIndices :: struct {
	graphics: Maybe(u32),
	present:  Maybe(u32),
}
find_queue_families :: proc(device: vk.PhysicalDevice) -> (ids: QueueFamilyIndices) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count, g_ctx.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if .GRAPHICS in family.queueFlags {
			ids.graphics = u32(i)
		}

		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), g_surface, &supported)
		if supported {
			ids.present = u32(i)
		}

		// Found all needed queues?
		_, has_graphics := ids.graphics.?
		_, has_present := ids.present.?
		if has_graphics && has_present {
			break
		}
	}
	return
}

SwapchainSupport :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}
query_swapchain_support :: proc(
	device: vk.PhysicalDevice,
) -> (
	support: SwapchainSupport,
	result: vk.Result,
) {
	// NOTE: looks like a wrong binding with the third arg being a multipointer.
	log.info("vulkan: querying swapchain support for device %v", device)
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, g_surface, &support.capabilities) or_return
	log.info("vulkan: got surface capabilities %v", support.capabilities)
	{
		count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, g_surface, &count, nil) or_return

		log.infof("vulkan: found %v surface formats", count)

		support.formats = make([]vk.SurfaceFormatKHR, count, g_ctx.temp_allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			device,
			g_surface,
			&count,
			raw_data(support.formats),
		) or_return
	}

	{
		count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, g_surface, &count, nil) or_return

		support.presentModes = make([]vk.PresentModeKHR, count, g_ctx.temp_allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			g_surface,
			&count,
			raw_data(support.presentModes),
		) or_return
	}
	return
}

pick_physical_device :: proc() -> vk.Result {
	get_available_extensions :: proc(
		device: vk.PhysicalDevice,
	) -> (
		exts: []vk.ExtensionProperties,
		res: vk.Result,
	) {
		count: u32
		vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) or_return
		exts = make([]vk.ExtensionProperties, count, g_ctx.temp_allocator)
		vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(exts)) or_return
		return
	}
	score_physical_device :: proc(device: vk.PhysicalDevice) -> (score: int) {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)
		name := strings.truncate_to_byte(string(props.deviceName[:]), 0)
		log.infof("vulkan: evaluating device %q", name)
		defer log.infof("vulkan: device %q scored %v", name, score)
		features: vk.PhysicalDeviceFeatures
		vk.GetPhysicalDeviceFeatures(device, &features)
		// App can't function without geometry shaders.
		if !features.geometryShader {
			log.info("vulkan: device does not support geometry shaders")
			return 0
		}
		// Need certain extensions supported.
		{
			extensions, result := get_available_extensions(device)
			if result != .SUCCESS {
				log.infof("vulkan: enumerate device extension properties failed: %v", result)
				return 0
			}
			log.infof("vulkan: device supports %v extensions", len(extensions))
			required_loop: for required in REQUIRED_EXTENSIONS {
				log.infof("vulkan: checking for required extension %q", required)
				for &extension in extensions {
					extension_name := strings.truncate_to_byte(
						string(extension.extensionName[:]),
						0,
					)
					if extension_name == string(required) {
						continue required_loop
					}
				}
				log.infof("vulkan: device does not support required extension %q", required)
				return 0
			}
			log.info("vulkan: device supports all required extensions")
		}
		{
			support, result := query_swapchain_support(device)
			if result != .SUCCESS {
				log.infof("vulkan: query swapchain support failure: %v", result)
				return 0
			}
			// Need at least a format and present mode.
			if len(support.formats) == 0 || len(support.presentModes) == 0 {
				log.info("vulkan: device does not support swapchain")
				return 0
			}
		}

		families := find_queue_families(device)
		if _, has_graphics := families.graphics.?; !has_graphics {
			log.info("vulkan: device does not have a graphics queue")
			return 0
		}
		if _, has_present := families.present.?; !has_present {
			log.info("vulkan: device does not have a presentation queue")
			return 0
		}

		// Favor GPUs.
		switch props.deviceType {
		case .DISCRETE_GPU:
			score += 400_000
		case .INTEGRATED_GPU:
			score += 300_000
		case .VIRTUAL_GPU:
			score += 200_000
		case .CPU, .OTHER:
			score += 100_000
		}
		log.infof("vulkan: scored %i based on device type %v", score, props.deviceType)

		// Maximum texture size.
		score += int(props.limits.maxImageDimension2D)
		log.infof(
			"vulkan: added the max 2D image dimensions (texture size) of %v to the score",
			props.limits.maxImageDimension2D,
		)
		return
	}

	count: u32
	vk.EnumeratePhysicalDevices(g_instance, &count, nil) or_return
	if count == 0 {
		log.panic("vulkan: no GPU found")
	}

	devices := make([]vk.PhysicalDevice, count, g_ctx.temp_allocator)
	vk.EnumeratePhysicalDevices(g_instance, &count, raw_data(devices)) or_return

	best_device_score := -1
	for device in devices {
		if score := score_physical_device(device); score > best_device_score {
			g_physical_device = device
			best_device_score = score
		}
	}

	if best_device_score <= 0 {
		log.panic("vulkan: no suitable GPU found")
	}
	return .SUCCESS
}

create_logical_device :: proc() -> vk.Result {
	families := find_queue_families(g_physical_device)
	indices_set := make(map[u32]struct {})
	indices_set[families.graphics.?] = {}
	indices_set[families.present.?] = {}

	queue_create_infos := make(
		[dynamic]vk.DeviceQueueCreateInfo,
		0,
		len(indices_set),
		g_ctx.temp_allocator,
	)
	for _ in indices_set {
		append(
			&queue_create_infos,
			vk.DeviceQueueCreateInfo {
				sType = .DEVICE_QUEUE_CREATE_INFO,
				queueFamilyIndex = families.graphics.?,
				queueCount = 1,
				pQueuePriorities = raw_data([]f32{1}),
			}, // Scheduling priority between 0 and 1.
		)
	}

	when ENABLE_VALIDATION_LAYERS {
		layers := []cstring{"VK_LAYER_KHRONOS_validation"}
	} else {
		layers := []cstring{}
	}

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pQueueCreateInfos       = raw_data(queue_create_infos),
		queueCreateInfoCount    = u32(len(queue_create_infos)),
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		ppEnabledExtensionNames = raw_data(REQUIRED_EXTENSIONS),
		enabledExtensionCount   = u32(len(REQUIRED_EXTENSIONS)),
	}
	vk.CreateDevice(g_physical_device, &device_create_info, nil, &g_device) or_return
	vk.GetDeviceQueue(g_device, families.graphics.?, 0, &g_graphics_queue)
	vk.GetDeviceQueue(g_device, families.present.?, 0, &g_present_queue)
	return .SUCCESS
}

create_swapchain :: proc() -> (result: vk.Result) {
	pick_swapchain_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
		for format in formats {
			if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
				return format
			}
		}
		return formats[0]
	}

	pick_swapchain_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
		for mode in modes {
			if mode == .MAILBOX {
				return .MAILBOX
			}
		}
		return .FIFO
	}

	pick_swapchain_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
		if capabilities.currentExtent.width != max(u32) {
			return capabilities.currentExtent
		}
		width, height := glfw.GetFramebufferSize(g_window)
		return (vk.Extent2D {
					width = clamp(
						u32(width),
						capabilities.minImageExtent.width,
						capabilities.maxImageExtent.width,
					),
					height = clamp(
						u32(height),
						capabilities.minImageExtent.height,
						capabilities.maxImageExtent.height,
					),
				})
	}
	families := find_queue_families(g_physical_device)

	// Setup swapchain.
	{
		support := query_swapchain_support(g_physical_device) or_return
		surface_format := pick_swapchain_surface_format(support.formats)
		present_mode := pick_swapchain_present_mode(support.presentModes)
		extent := pick_swapchain_extent(support.capabilities)

		g_swapchain_format = surface_format
		g_swapchain_extent = extent

		image_count := support.capabilities.minImageCount + 1
		if support.capabilities.maxImageCount > 0 &&
		   image_count > support.capabilities.maxImageCount {
			image_count = support.capabilities.maxImageCount
		}

		create_info := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = g_surface,
			minImageCount    = image_count,
			imageFormat      = surface_format.format,
			imageColorSpace  = surface_format.colorSpace,
			imageExtent      = extent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = support.capabilities.currentTransform,
			compositeAlpha   = {.OPAQUE},
			presentMode      = present_mode,
			clipped          = true,
		}

		if families.graphics != families.present {
			create_info.imageSharingMode = .CONCURRENT
			create_info.queueFamilyIndexCount = 2
			create_info.pQueueFamilyIndices = raw_data(
				[]u32{families.graphics.?, families.present.?},
			)
		}

		vk.CreateSwapchainKHR(g_device, &create_info, nil, &g_swapchain) or_return
	}

	// Setup swapchain images.
	{
		count: u32
		vk.GetSwapchainImagesKHR(g_device, g_swapchain, &count, nil) or_return

		g_swapchain_images = make([]vk.Image, count)
		g_swapchain_views = make([]vk.ImageView, count)
		vk.GetSwapchainImagesKHR(
			g_device,
			g_swapchain,
			&count,
			raw_data(g_swapchain_images),
		) or_return

		for image, i in g_swapchain_images {
			create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2,
				format = g_swapchain_format.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			vk.CreateImageView(g_device, &create_info, nil, &g_swapchain_views[i]) or_return
		}
	}
	return .SUCCESS
}

destroy_swapchain :: proc() {
	for view in g_swapchain_views {
		vk.DestroyImageView(g_device, view, nil)
	}
	delete(g_swapchain_views)
	delete(g_swapchain_images)
	vk.DestroySwapchainKHR(g_device, g_swapchain, nil)
}

// 5. Create graphics pipeline
create_shader_module :: proc(code: []u8) -> (module: vk.ShaderModule, result: vk.Result) {
	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(slice.reinterpret([]u32, code)),
	}
	vk.CreateShaderModule(g_device, &create_info, nil, &module) or_return
	return
}

load_shader :: proc() -> vk.Result {
	g_vert_shader_module = create_shader_module(SHADER_VERT) or_return
	g_shader_stages[0] = vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = g_vert_shader_module,
		pName  = "main",
	}

	g_frag_shader_module = create_shader_module(SHADER_FRAG) or_return
	g_shader_stages[1] = vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = g_frag_shader_module,
		pName  = "main",
	}
	return .SUCCESS
}

create_render_pass :: proc() -> vk.Result {
	color_attachment := vk.AttachmentDescription {
		format         = g_swapchain_format.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}
	color_attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}
	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}
	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	render_pass := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}
	return vk.CreateRenderPass(g_device, &render_pass, nil, &g_render_pass)
}

create_framebuffers :: proc() -> vk.Result {
	g_swapchain_frame_buffers = make([]vk.Framebuffer, len(g_swapchain_views))
	for view, i in g_swapchain_views {
		attachments := []vk.ImageView{view}

		frame_buffer := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = g_render_pass,
			attachmentCount = 1,
			pAttachments    = raw_data(attachments),
			width           = g_swapchain_extent.width,
			height          = g_swapchain_extent.height,
			layers          = 1,
		}
		vk.CreateFramebuffer(g_device, &frame_buffer, nil, &g_swapchain_frame_buffers[i]) or_return
	}
	return .SUCCESS
}

destroy_framebuffers :: proc() {
	for frame_buffer in g_swapchain_frame_buffers {
		vk.DestroyFramebuffer(g_device, frame_buffer, nil)
	}
	delete(g_swapchain_frame_buffers)
}

create_pipeline :: proc() -> vk.Result {
	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = raw_data(dynamic_states),
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth   = 1,
		cullMode    = {.BACK},
		frontFace   = .CLOCKWISE,
	}

	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		minSampleShading     = 1,
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	pipeline_layout := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	vk.CreatePipelineLayout(g_device, &pipeline_layout, nil, &g_pipeline_layout) or_return

	pipeline := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = &g_shader_stages[0],
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = g_pipeline_layout,
		renderPass          = g_render_pass,
		subpass             = 0,
		basePipelineIndex   = -1,
	}
	return vk.CreateGraphicsPipelines(g_device, 0, 1, &pipeline, nil, &g_pipeline)
}

// 7. Create command pool
create_command_pool :: proc() -> vk.Result {
	families := find_queue_families(g_physical_device)
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = families.graphics.?,
	}
	vk.CreateCommandPool(g_device, &pool_info, nil, &g_command_pool) or_return
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = g_command_pool,
		level              = .PRIMARY,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
	}
	return vk.AllocateCommandBuffers(g_device, &alloc_info, &g_command_buffers[0])
}

create_semaphores :: proc() -> vk.Result {
	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.CreateSemaphore(g_device, &sem_info, nil, &g_image_available_semaphores[i]) or_return
		vk.CreateSemaphore(g_device, &sem_info, nil, &g_render_finished_semaphores[i]) or_return
		vk.CreateFence(g_device, &fence_info, nil, &g_in_flight_fences[i]) or_return
	}
	return .SUCCESS
}

detroy_semaphores :: proc() {
	for sem in g_image_available_semaphores {
		vk.DestroySemaphore(g_device, sem, nil)
	}
	for sem in g_render_finished_semaphores {
		vk.DestroySemaphore(g_device, sem, nil)
	}
	for fence in g_in_flight_fences {
		vk.DestroyFence(g_device, fence, nil)
	}
}

// 8. Render loop
render :: proc() -> vk.Result {
	// Wait for previous frame.
	vk.WaitForFences(g_device, 1, &g_in_flight_fences[g_current_frame], true, max(u64)) or_return

	// Acquire an image from the swapchain.
	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		g_device,
		g_swapchain,
		max(u64),
		g_image_available_semaphores[g_current_frame],
		0,
		&image_index,
	)
	#partial switch acquire_result {
	case .ERROR_OUT_OF_DATE_KHR:
		recreate_swapchain()
		return .SUCCESS
	case .SUCCESS, .SUBOPTIMAL_KHR:
	case:
		log.panicf("vulkan: acquire next image failure: %v", acquire_result)
	}
	vk.ResetFences(g_device, 1, &g_in_flight_fences[g_current_frame]) or_return
	vk.ResetCommandBuffer(g_command_buffers[g_current_frame], {}) or_return
	record_command_buffer(g_command_buffers[g_current_frame], image_index) or_return

	// Submit.
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &g_image_available_semaphores[g_current_frame],
		pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},
		commandBufferCount   = 1,
		pCommandBuffers      = &g_command_buffers[g_current_frame],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &g_render_finished_semaphores[g_current_frame],
	}
	vk.QueueSubmit(
		g_graphics_queue,
		1,
		&submit_info,
		g_in_flight_fences[g_current_frame],
	) or_return
	// Present.
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &g_render_finished_semaphores[g_current_frame],
		swapchainCount     = 1,
		pSwapchains        = &g_swapchain,
		pImageIndices      = &image_index,
	}
	present_result := vk.QueuePresentKHR(g_present_queue, &present_info)
	switch {
	case present_result == .ERROR_OUT_OF_DATE_KHR ||
	     present_result == .SUBOPTIMAL_KHR ||
	     g_framebuffer_resized:
		g_framebuffer_resized = false
		recreate_swapchain()
	case present_result == .SUCCESS:
	case:
		log.panicf("vulkan: present failure: %v", present_result)
	}
	g_current_frame = (g_current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return .SUCCESS
}

record_command_buffer :: proc(command_buffer: vk.CommandBuffer, image_index: u32) -> vk.Result {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk.BeginCommandBuffer(command_buffer, &begin_info) or_return
	clear_color := vk.ClearValue {
		color = vk.ClearColorValue{float32 = {0.0, 0.0, 0.0, 1.0}},
	}

	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = g_render_pass,
		framebuffer = g_swapchain_frame_buffers[image_index],
		renderArea = {extent = g_swapchain_extent},
		clearValueCount = 1,
		pClearValues = &clear_color,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, g_pipeline)
	viewport := vk.Viewport {
		width    = f32(g_swapchain_extent.width),
		height   = f32(g_swapchain_extent.height),
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
	scissor := vk.Rect2D {
		extent = g_swapchain_extent,
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
	vk.CmdDraw(command_buffer, 3, 1, 0, 0)
	vk.CmdEndRenderPass(command_buffer)
	vk.EndCommandBuffer(command_buffer) or_return
	return .SUCCESS
}

recreate_swapchain :: proc() {
	// Don't do anything when minimized.
	for w, h := glfw.GetFramebufferSize(g_window);
	    w == 0 || h == 0;
	    w, h = glfw.GetFramebufferSize(g_window) {
		glfw.WaitEvents()
		if glfw.WindowShouldClose(g_window) {
			break
		}
	}

	vk.DeviceWaitIdle(g_device)

	destroy_framebuffers()
	destroy_swapchain()

	create_swapchain()
	create_framebuffers()
}
