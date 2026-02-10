package camera

import cont "../../containers"
import d "../../data"
import geo "../../geometry"
import "../../gpu"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: d.FRAMES_IN_FLIGHT
MAX_DEPTH_MIPS_LEVEL :: d.MAX_DEPTH_MIPS_LEVEL

// DepthPyramid - Hierarchical depth buffer for occlusion culling (GPU resource)
DepthPyramid :: struct {
	texture:    d.Image2DHandle,
	views:      [MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
	full_view:  vk.ImageView,
	sampler:    vk.Sampler,
	mip_levels: u32,
	width:      u32,
	height:     u32,
}

// CameraGPU - GPU-side camera resources (managed by Render module)
// Parallel array indexed by CameraHandle, allocated/freed by render module
CameraGPU :: struct {
	// Render target attachments (G-buffer textures, depth, final image)
	attachments:                  [d.AttachmentType][FRAMES_IN_FLIGHT]d.Image2DHandle,
	// Per-frame camera buffer descriptor sets used by graphics/compute passes
	camera_buffer_descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
	// Indirect draw buffers (double-buffered for async compute)
	// Frame N compute writes to buffers[N], Frame N graphics reads from buffers[N-1]
	opaque_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
	opaque_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
	transparent_draw_count:       [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
	transparent_draw_commands:    [FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
	sprite_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
	sprite_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
	// Depth pyramid for hierarchical Z culling
	depth_pyramid:                [FRAMES_IN_FLIGHT]DepthPyramid,
	// Descriptor sets for visibility culling compute shaders
	descriptor_set:               [FRAMES_IN_FLIGHT]vk.DescriptorSet,
	depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

// SphericalCameraGPU - GPU-side spherical camera resources (for point light shadows)
SphericalCameraGPU :: struct {
	// Cube depth textures (per-frame double-buffering)
	depth_cube:      [FRAMES_IN_FLIGHT]d.ImageCubeHandle,
	// Indirect draw buffers
	draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
	draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
	// Descriptor sets for sphere culling
	descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

// Initialize GPU resources for perspective camera
// Takes only the specific resources needed, no dependency on render manager
init_gpu :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^CameraGPU,
	camera_cpu: ^d.Camera,
	texture_manager: ^gpu.TextureManager,
	width, height: u32,
	color_format, depth_format: vk.Format,
	enabled_passes: d.PassTypeSet,
	max_draws: u32,
) -> vk.Result {
	// Determine which attachments are needed based on enabled passes
	needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
	needs_final :=
		.LIGHTING in enabled_passes ||
		.TRANSPARENCY in enabled_passes ||
		.PARTICLES in enabled_passes ||
		.POST_PROCESS in enabled_passes

	// Create render target attachments for each frame
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		if needs_final {
			camera_gpu.attachments[.FINAL_IMAGE][frame] =
				gpu.allocate_texture_2d(
					texture_manager,
					gctx,
					width,
					height,
					color_format,
					{.COLOR_ATTACHMENT, .SAMPLED},
				) or_return
		}
		if needs_gbuffer {
			camera_gpu.attachments[.POSITION][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R32G32B32A32_SFLOAT, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.NORMAL][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.ALBEDO][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.METALLIC_ROUGHNESS][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.EMISSIVE][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
		}
		camera_gpu.attachments[.DEPTH][frame] =
			gpu.allocate_texture_2d(
				texture_manager,
				gctx,
				width,
				height,
				depth_format,
				{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
			) or_return

		// Transition depth image from UNDEFINED to DEPTH_STENCIL_READ_ONLY_OPTIMAL
		if depth := gpu.get_texture_2d(texture_manager, camera_gpu.attachments[.DEPTH][frame]); depth != nil {
			cmd_buf := gpu.begin_single_time_command(gctx) or_return
			gpu.image_barrier(
				cmd_buf,
				depth.image,
				.UNDEFINED,
				.DEPTH_STENCIL_READ_ONLY_OPTIMAL,
				{},
				{.DEPTH_STENCIL_ATTACHMENT_READ},
				{.TOP_OF_PIPE},
				{.EARLY_FRAGMENT_TESTS},
				{.DEPTH},
			)
			gpu.end_single_time_command(gctx, &cmd_buf) or_return
		}
	}

	// Create indirect draw buffers (double-buffered)
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		camera_gpu.opaque_draw_count[frame] = gpu.create_mutable_buffer(
			gctx,
			u32,
			1,
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
		camera_gpu.opaque_draw_commands[frame] = gpu.create_mutable_buffer(
			gctx,
			vk.DrawIndexedIndirectCommand,
			int(max_draws),
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
		camera_gpu.transparent_draw_count[frame] = gpu.create_mutable_buffer(
			gctx,
			u32,
			1,
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
		camera_gpu.transparent_draw_commands[frame] = gpu.create_mutable_buffer(
			gctx,
			vk.DrawIndexedIndirectCommand,
			int(max_draws),
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
		camera_gpu.sprite_draw_count[frame] = gpu.create_mutable_buffer(
			gctx,
			u32,
			1,
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
		camera_gpu.sprite_draw_commands[frame] = gpu.create_mutable_buffer(
			gctx,
			vk.DrawIndexedIndirectCommand,
			int(max_draws),
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
	}

	// Create depth pyramids for hierarchical Z culling
	if camera_cpu.enable_depth_pyramid {
		for frame in 0 ..< FRAMES_IN_FLIGHT {
			create_depth_pyramid(
				gctx,
				camera_gpu,
				texture_manager,
				width,
				height,
				u32(frame),
			) or_return
		}
	}

	return .SUCCESS
}

// Initialize GPU resources for orthographic camera (same as perspective)
init_orthographic_gpu :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^CameraGPU,
	camera_cpu: ^d.Camera,
	texture_manager: ^gpu.TextureManager,
	width, height: u32,
	color_format, depth_format: vk.Format,
	enabled_passes: d.PassTypeSet,
	max_draws: u32,
) -> vk.Result {
	return init_gpu(
		gctx,
		camera_gpu,
		camera_cpu,
		texture_manager,
		width,
		height,
		color_format,
		depth_format,
		enabled_passes,
		max_draws,
	)
}

// Initialize GPU resources for spherical camera (omnidirectional shadow mapping)
init_spherical_gpu :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^SphericalCameraGPU,
	texture_manager: ^gpu.TextureManager,
	size: u32,
	depth_format: vk.Format,
	max_draws: u32,
) -> vk.Result {
	// Create cube depth textures for omnidirectional shadows
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		camera_gpu.depth_cube[frame] =
			gpu.allocate_texture_cube(
				texture_manager,
				gctx,
				size,
				depth_format,
				{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
			) or_return
	}

	// Create indirect draw buffers
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		camera_gpu.draw_count[frame] = gpu.create_mutable_buffer(
			gctx,
			u32,
			1,
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
		camera_gpu.draw_commands[frame] = gpu.create_mutable_buffer(
			gctx,
			vk.DrawIndexedIndirectCommand,
			int(max_draws),
			{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
		) or_return
	}

	return .SUCCESS
}

// Destroy GPU resources for perspective/orthographic camera
destroy_gpu :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^CameraGPU,
	texture_manager: ^gpu.TextureManager,
) {
	// Destroy all attachment textures
	for attachment_type in d.AttachmentType {
		for frame in 0 ..< FRAMES_IN_FLIGHT {
			handle := camera_gpu.attachments[attachment_type][frame]
			if handle.index == 0 do continue
			gpu.free_texture_2d(texture_manager, gctx, handle)
		}
	}

	// Destroy depth pyramids
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		pyramid := &camera_gpu.depth_pyramid[frame]
		if pyramid.mip_levels == 0 do continue

		for mip in 0 ..< pyramid.mip_levels {
			vk.DestroyImageView(gctx.device, pyramid.views[mip], nil)
		}
		vk.DestroyImageView(gctx.device, pyramid.full_view, nil)
		vk.DestroySampler(gctx.device, pyramid.sampler, nil)

		gpu.free_texture_2d(texture_manager, gctx, pyramid.texture)
	}

	// Destroy indirect draw buffers
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.opaque_draw_count[frame])
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.opaque_draw_commands[frame])
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.transparent_draw_count[frame])
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.transparent_draw_commands[frame])
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.sprite_draw_count[frame])
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.sprite_draw_commands[frame])
	}

	// Zero out the GPU struct
	camera_gpu^ = {}
}

// Destroy GPU resources for spherical camera
destroy_spherical_gpu :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^SphericalCameraGPU,
	texture_manager: ^gpu.TextureManager,
) {
	// Destroy cube depth textures
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		handle := camera_gpu.depth_cube[frame]
		if handle.index == 0 do continue
		gpu.free_texture_cube(texture_manager, gctx, handle)
	}

	// Destroy indirect draw buffers
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.draw_count[frame])
		gpu.mutable_buffer_destroy(gctx.device, &camera_gpu.draw_commands[frame])
	}

	// Zero out the GPU struct
	camera_gpu^ = {}
}

// Allocate descriptor sets for spherical camera
allocate_descriptors_spherical :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^SphericalCameraGPU,
	descriptor_layout: ^vk.DescriptorSetLayout,
	node_data_buffer: ^gpu.BindlessBuffer(d.NodeData),
	mesh_data_buffer: ^gpu.BindlessBuffer(d.MeshData),
	world_matrix_buffer: ^gpu.BindlessBuffer(matrix[4, 4]f32),
	spherical_camera_buffer: ^gpu.PerFrameBindlessBuffer(d.SphericalCameraData, FRAMES_IN_FLIGHT),
) -> vk.Result {
	// Create per-frame descriptor sets for sphere culling compute shader
	for frame_index in 0 ..< FRAMES_IN_FLIGHT {
		camera_gpu.descriptor_sets[frame_index] = gpu.create_descriptor_set(
			gctx,
			descriptor_layout,
			{.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
			{.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
			{.STORAGE_BUFFER, gpu.buffer_info(&world_matrix_buffer.buffer)},
			{
				.STORAGE_BUFFER,
				gpu.buffer_info(&spherical_camera_buffer.buffers[frame_index]),
			},
			{.STORAGE_BUFFER, gpu.buffer_info(&camera_gpu.draw_count[frame_index])},
			{.STORAGE_BUFFER, gpu.buffer_info(&camera_gpu.draw_commands[frame_index])},
		) or_return
	}

	return .SUCCESS
}

// Allocate descriptor sets for perspective/orthographic camera culling pipelines
allocate_descriptors :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^CameraGPU,
	texture_manager: ^gpu.TextureManager,
	normal_descriptor_layout: ^vk.DescriptorSetLayout,
	depth_reduce_descriptor_layout: ^vk.DescriptorSetLayout,
	node_data_buffer: ^gpu.BindlessBuffer(d.NodeData),
	mesh_data_buffer: ^gpu.BindlessBuffer(d.MeshData),
	world_matrix_buffer: ^gpu.BindlessBuffer(matrix[4, 4]f32),
	camera_buffer: ^gpu.PerFrameBindlessBuffer(d.CameraData, FRAMES_IN_FLIGHT),
) -> vk.Result {
	for frame_index in 0 ..< FRAMES_IN_FLIGHT {
		camera_gpu.camera_buffer_descriptor_sets[frame_index] =
			camera_buffer.descriptor_sets[frame_index]
		prev_frame_index := (frame_index + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT
		pyramid := &camera_gpu.depth_pyramid[frame_index]
		prev_pyramid := &camera_gpu.depth_pyramid[prev_frame_index]
		prev_depth := gpu.get_texture_2d(
			texture_manager,
			camera_gpu.attachments[.DEPTH][prev_frame_index],
		)
		if prev_depth == nil {
			log.errorf(
				"allocate_descriptors: missing depth attachment for frame %d",
				prev_frame_index,
			)
			return .ERROR_INITIALIZATION_FAILED
		}
		if pyramid.mip_levels == 0 {
			log.errorf(
				"allocate_descriptors: missing depth pyramid for frame %d",
				frame_index,
			)
			return .ERROR_INITIALIZATION_FAILED
		}

		camera_gpu.descriptor_set[frame_index] = gpu.create_descriptor_set(
			gctx,
			normal_descriptor_layout,
			{.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
			{.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
			{.STORAGE_BUFFER, gpu.buffer_info(&world_matrix_buffer.buffer)},
			{
				.STORAGE_BUFFER,
				gpu.buffer_info(&camera_buffer.buffers[frame_index]),
			},
			{.STORAGE_BUFFER, gpu.buffer_info(&camera_gpu.opaque_draw_count[frame_index])},
			{.STORAGE_BUFFER, gpu.buffer_info(&camera_gpu.opaque_draw_commands[frame_index])},
			{
				.STORAGE_BUFFER,
				gpu.buffer_info(&camera_gpu.transparent_draw_count[frame_index]),
			},
			{
				.STORAGE_BUFFER,
				gpu.buffer_info(&camera_gpu.transparent_draw_commands[frame_index]),
			},
			{.STORAGE_BUFFER, gpu.buffer_info(&camera_gpu.sprite_draw_count[frame_index])},
			{.STORAGE_BUFFER, gpu.buffer_info(&camera_gpu.sprite_draw_commands[frame_index])},
			{
				.COMBINED_IMAGE_SAMPLER,
				vk.DescriptorImageInfo {
					sampler     = prev_pyramid.sampler,
					imageView   = prev_pyramid.full_view,
					imageLayout = .GENERAL,
				},
			},
		) or_return

		for mip in 0 ..< pyramid.mip_levels {
			source_info: vk.DescriptorImageInfo
			if mip == 0 {
				source_info = {
					sampler     = pyramid.sampler,
					imageView   = prev_depth.view,
					imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
				}
			} else {
				source_info = {
					sampler     = pyramid.sampler,
					imageView   = pyramid.views[mip - 1],
					imageLayout = .GENERAL,
				}
			}
			dest_info := vk.DescriptorImageInfo {
				imageView   = pyramid.views[mip],
				imageLayout = .GENERAL,
			}
			camera_gpu.depth_reduce_descriptor_sets[frame_index][mip] = gpu.create_descriptor_set(
				gctx,
				depth_reduce_descriptor_layout,
				{.COMBINED_IMAGE_SAMPLER, source_info},
				{.STORAGE_IMAGE, dest_info},
			) or_return
		}
	}

	return .SUCCESS
}

get_attachment :: proc(
	camera_gpu: ^CameraGPU,
	attachment_type: d.AttachmentType,
	frame_index: u32 = 0,
) -> d.Image2DHandle {
	return camera_gpu.attachments[attachment_type][frame_index]
}

// Resize camera render targets (called on window resize)
resize_gpu :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^CameraGPU,
	camera_cpu: ^d.Camera,
	texture_manager: ^gpu.TextureManager,
	width, height: u32,
	color_format, depth_format: vk.Format,
) -> vk.Result {
	enabled_passes := camera_cpu.enabled_passes

	// Destroy old attachments
	for attachment_type in d.AttachmentType {
		for frame in 0 ..< FRAMES_IN_FLIGHT {
			handle := camera_gpu.attachments[attachment_type][frame]
			if handle.index == 0 do continue
			gpu.free_texture_2d(texture_manager, gctx, handle)
			camera_gpu.attachments[attachment_type][frame] = {}
		}
	}

	// Destroy old depth pyramids
	for frame in 0 ..< FRAMES_IN_FLIGHT {
		pyramid := &camera_gpu.depth_pyramid[frame]
		if pyramid.mip_levels == 0 do continue

		for mip in 0 ..< pyramid.mip_levels {
			vk.DestroyImageView(gctx.device, pyramid.views[mip], nil)
		}
		vk.DestroyImageView(gctx.device, pyramid.full_view, nil)
		vk.DestroySampler(gctx.device, pyramid.sampler, nil)

		gpu.free_texture_2d(texture_manager, gctx, pyramid.texture)
		pyramid^ = {}
	}

	// Recreate attachments with new dimensions
	needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
	needs_final :=
		.LIGHTING in enabled_passes ||
		.TRANSPARENCY in enabled_passes ||
		.PARTICLES in enabled_passes ||
		.POST_PROCESS in enabled_passes

	for frame in 0 ..< FRAMES_IN_FLIGHT {
		if needs_final {
			camera_gpu.attachments[.FINAL_IMAGE][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, color_format, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
		}
		if needs_gbuffer {
			camera_gpu.attachments[.POSITION][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R32G32B32A32_SFLOAT, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.NORMAL][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.ALBEDO][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.METALLIC_ROUGHNESS][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
			camera_gpu.attachments[.EMISSIVE][frame] =
				gpu.allocate_texture_2d(texture_manager, gctx, width, height, .R8G8B8A8_UNORM, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
		}
		camera_gpu.attachments[.DEPTH][frame] =
			gpu.allocate_texture_2d(
				texture_manager,
				gctx,
				width,
				height,
				depth_format,
				{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
			) or_return

		if depth := gpu.get_texture_2d(texture_manager, camera_gpu.attachments[.DEPTH][frame]); depth != nil {
			cmd_buf := gpu.begin_single_time_command(gctx) or_return
			gpu.image_barrier(
				cmd_buf,
				depth.image,
				.UNDEFINED,
				.DEPTH_STENCIL_READ_ONLY_OPTIMAL,
				{},
				{.DEPTH_STENCIL_ATTACHMENT_READ},
				{.TOP_OF_PIPE},
				{.EARLY_FRAGMENT_TESTS},
				{.DEPTH},
			)
			gpu.end_single_time_command(gctx, &cmd_buf) or_return
		}
	}

	// Recreate depth pyramids
	if camera_cpu.enable_depth_pyramid {
		for frame in 0 ..< FRAMES_IN_FLIGHT {
			create_depth_pyramid(gctx, camera_gpu, texture_manager, width, height, u32(frame)) or_return
		}
	}

	// Update camera CPU extent
	camera_cpu.extent = {width, height}

	// Update aspect ratio for perspective projection
	if proj, ok := &camera_cpu.projection.(d.PerspectiveProjection); ok {
		proj.aspect_ratio = f32(width) / f32(height)
	}

	log.infof("Camera resized to %dx%d", width, height)
	return .SUCCESS
}

// Helper: Create depth pyramid for hierarchical Z culling
@(private)
create_depth_pyramid :: proc(
	gctx: ^gpu.GPUContext,
	camera_gpu: ^CameraGPU,
	texture_manager: ^gpu.TextureManager,
	width: u32,
	height: u32,
	frame_index: u32,
) -> vk.Result {
	pyramid_width := max(1, width / 2)
	pyramid_height := max(1, height / 2)
	mip_levels := u32(math.floor(math.log2(f32(max(pyramid_width, pyramid_height))))) + 1

	pyramid_handle := gpu.allocate_texture_2d(
		texture_manager,
		gctx,
		pyramid_width,
		pyramid_height,
		.R32_SFLOAT,
		{.SAMPLED, .STORAGE, .TRANSFER_DST},
		true, // generate_mips
	) or_return

	pyramid_texture := gpu.get_texture_2d(texture_manager, pyramid_handle)
	if pyramid_texture == nil {
		log.error("Failed to get allocated depth pyramid texture")
		return .ERROR_OUT_OF_DEVICE_MEMORY
	}

	// Transition all mip levels to GENERAL layout
	{
		cmd_buf := gpu.begin_single_time_command(gctx) or_return
		gpu.image_barrier(
			cmd_buf,
			pyramid_texture.image,
			.UNDEFINED,
			.GENERAL,
			{},
			{.SHADER_READ, .SHADER_WRITE},
			{.TOP_OF_PIPE},
			{.COMPUTE_SHADER},
			{.COLOR},
			level_count = mip_levels,
		)
		gpu.end_single_time_command(gctx, &cmd_buf) or_return
	}

	camera_gpu.depth_pyramid[frame_index].texture = pyramid_handle
	camera_gpu.depth_pyramid[frame_index].mip_levels = mip_levels
	camera_gpu.depth_pyramid[frame_index].width = pyramid_width
	camera_gpu.depth_pyramid[frame_index].height = pyramid_height

	// Create per-mip views
	for mip in 0 ..< mip_levels {
		view_info := vk.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = pyramid_texture.image,
			viewType = .D2,
			format = .R32_SFLOAT,
			subresourceRange = {aspectMask = {.COLOR}, baseMipLevel = mip, levelCount = 1, layerCount = 1},
		}
		vk.CreateImageView(gctx.device, &view_info, nil, &camera_gpu.depth_pyramid[frame_index].views[mip]) or_return
	}

	// Create full pyramid view
	full_view_info := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = pyramid_texture.image,
		viewType = .D2,
		format = .R32_SFLOAT,
		subresourceRange = {aspectMask = {.COLOR}, baseMipLevel = 0, levelCount = mip_levels, layerCount = 1},
	}
	vk.CreateImageView(gctx.device, &full_view_info, nil, &camera_gpu.depth_pyramid[frame_index].full_view) or_return

	// Create sampler for depth pyramid with MAX reduction for forward-Z
	reduction_mode := vk.SamplerReductionModeCreateInfo {
		sType         = .SAMPLER_REDUCTION_MODE_CREATE_INFO,
		reductionMode = .MAX,
	}
	sampler_info := vk.SamplerCreateInfo{
		sType = .SAMPLER_CREATE_INFO,
		magFilter = .LINEAR,
		minFilter = .LINEAR,
		mipmapMode = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		minLod = 0.0,
		maxLod = f32(mip_levels),
		borderColor = .FLOAT_OPAQUE_WHITE,
		pNext = &reduction_mode,
	}
	vk.CreateSampler(gctx.device, &sampler_info, nil, &camera_gpu.depth_pyramid[frame_index].sampler) or_return

	return .SUCCESS
}

