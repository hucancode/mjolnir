package world

import "core:log"
import "core:math"
import gpu "../gpu"
import resources "../resources"
import vk "vendor:vulkan"

// Depth pyramid for hierarchical occlusion culling
// Based on Niagara's approach - generates mip chain of minimum depth values
// Used for GPU-driven occlusion testing

DepthPyramid :: struct {
	image:                 vk.Image,
	image_view:            vk.ImageView,
	memory:                vk.DeviceMemory,
	mip_views:             [16]vk.ImageView, // Per-mip views for reduction
	width:                 u32,
	height:                u32,
	mip_levels:            u32,
	sampler:               vk.Sampler, // MIN reduction sampler
	descriptor_set_layout: vk.DescriptorSetLayout,
	pipeline_layout:       vk.PipelineLayout,
	pipeline:              vk.Pipeline,
}

DepthPyramidPushConstants :: struct {
	image_size: [2]f32,
	mip_level:  u32,
	_padding:   u32,
}

depth_pyramid_init :: proc(
	pyramid: ^DepthPyramid,
	gpu_context: ^gpu.GPUContext,
	width, height: u32,
) -> vk.Result {
	// Use power-of-2 dimensions for conservative reduction
	pyramid.width = previous_pow2(width)
	pyramid.height = previous_pow2(height)
	pyramid.mip_levels = get_mip_levels(pyramid.width, pyramid.height)

	// Create depth pyramid image
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = .R32_SFLOAT, // Store depth as float
		extent        = {pyramid.width, pyramid.height, 1},
		mipLevels     = pyramid.mip_levels,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.SAMPLED, .STORAGE, .TRANSFER_SRC}, // STORAGE for compute writes
		initialLayout = .UNDEFINED,
	}

	vk.CreateImage(
		gpu_context.device,
		&image_info,
		nil,
		&pyramid.image,
	) or_return

	// Allocate memory
	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(gpu_context.device, pyramid.image, &mem_reqs)

	mem_type_index, found := gpu.find_memory_type_index(
		gpu_context.physical_device,
		mem_reqs.memoryTypeBits,
		{.DEVICE_LOCAL},
	)
	if !found {
		return .ERROR_OUT_OF_DEVICE_MEMORY
	}

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type_index,
	}

	vk.AllocateMemory(gpu_context.device, &alloc_info, nil, &pyramid.memory) or_return
	vk.BindImageMemory(gpu_context.device, pyramid.image, pyramid.memory, 0) or_return

	// Create main image view for sampling
	view_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = pyramid.image,
		viewType         = .D2,
		format           = .R32_SFLOAT,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = pyramid.mip_levels,
			layerCount = 1,
		},
	}

	vk.CreateImageView(
		gpu_context.device,
		&view_info,
		nil,
		&pyramid.image_view,
	) or_return

	// Create per-mip views for compute shader writes
	for i in 0 ..< pyramid.mip_levels {
		mip_view_info := view_info
		mip_view_info.subresourceRange.baseMipLevel = i
		mip_view_info.subresourceRange.levelCount = 1

		vk.CreateImageView(
			gpu_context.device,
			&mip_view_info,
			nil,
			&pyramid.mip_views[i],
		) or_return
	}

	// Create sampler for depth pyramid (standard sampler - MIN reduction done in compute shader)
	sampler_info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = .LINEAR,
		minFilter               = .LINEAR,
		mipmapMode              = .NEAREST,
		addressModeU            = .CLAMP_TO_EDGE,
		addressModeV            = .CLAMP_TO_EDGE,
		addressModeW            = .CLAMP_TO_EDGE,
		minLod                  = 0,
		maxLod                  = f32(pyramid.mip_levels),
	}

	vk.CreateSampler(gpu_context.device, &sampler_info, nil, &pyramid.sampler) or_return

	// Create descriptor set layout for reduction pass
	bindings := [?]vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .STORAGE_IMAGE, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Output mip
		{binding = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Input (previous mip or depth)
	}

	vk.CreateDescriptorSetLayout(
		gpu_context.device,
		&vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = len(bindings),
			pBindings = raw_data(bindings[:]),
		},
		nil,
		&pyramid.descriptor_set_layout,
	) or_return

	// Create pipeline layout
	push_range := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		size       = size_of(DepthPyramidPushConstants),
	}

	vk.CreatePipelineLayout(
		gpu_context.device,
		&vk.PipelineLayoutCreateInfo {
			sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount         = 1,
			pSetLayouts            = &pyramid.descriptor_set_layout,
			pushConstantRangeCount = 1,
			pPushConstantRanges    = &push_range,
		},
		nil,
		&pyramid.pipeline_layout,
	) or_return

	// Create compute pipeline
        shader_module := gpu.create_shader_module(
                gpu_context.device,
                #load("../shader/depth_pyramid/reduce.spv"),
        ) or_return
	defer vk.DestroyShaderModule(gpu_context.device, shader_module, nil)

	compute_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		stage  = {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.COMPUTE},
			module = shader_module,
			pName  = "main",
		},
		layout = pyramid.pipeline_layout,
	}

	vk.CreateComputePipelines(
		gpu_context.device,
		0,
		1,
		&compute_info,
		nil,
		&pyramid.pipeline,
	) or_return

	log.infof(
		"Depth pyramid initialized: %dx%d, %d mip levels",
		pyramid.width,
		pyramid.height,
		pyramid.mip_levels,
	)

	return .SUCCESS
}

depth_pyramid_shutdown :: proc(pyramid: ^DepthPyramid, device: vk.Device) {
	vk.DestroyPipeline(device, pyramid.pipeline, nil)
	vk.DestroyPipelineLayout(device, pyramid.pipeline_layout, nil)
	vk.DestroyDescriptorSetLayout(device, pyramid.descriptor_set_layout, nil)
	vk.DestroySampler(device, pyramid.sampler, nil)

	for i in 0 ..< pyramid.mip_levels {
		vk.DestroyImageView(device, pyramid.mip_views[i], nil)
	}

	vk.DestroyImageView(device, pyramid.image_view, nil)
	vk.DestroyImage(device, pyramid.image, nil)
	vk.FreeMemory(device, pyramid.memory, nil)

	pyramid^ = {}
}

// Generate depth pyramid from depth buffer
depth_pyramid_generate :: proc(
        pyramid: ^DepthPyramid,
        gpu_context: ^gpu.GPUContext,
        cmd: vk.CommandBuffer,
        source_depth_view: vk.ImageView,
        source_width, source_height: u32,
) {
	// Transition pyramid to GENERAL layout for compute writes
	barrier := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {},
		dstAccessMask       = {.SHADER_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .GENERAL,
		image               = pyramid.image,
		subresourceRange    = {
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = pyramid.mip_levels,
			layerCount     = 1,
		},
	}

	vk.CmdPipelineBarrier(
		cmd,
		{.TOP_OF_PIPE},
		{.COMPUTE_SHADER},
		{},
		0, nil,
		0, nil,
		1, &barrier,
	)

	vk.CmdBindPipeline(cmd, .COMPUTE, pyramid.pipeline)

	// Generate each mip level
	for i in 0 ..< pyramid.mip_levels {
		mip_width := max(1, pyramid.width >> i)
		mip_height := max(1, pyramid.height >> i)

		// Allocate descriptor set for this reduction
		descriptor_set: vk.DescriptorSet
		vk.AllocateDescriptorSets(
			gpu_context.device,
			&vk.DescriptorSetAllocateInfo {
				sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
				descriptorPool = gpu_context.descriptor_pool,
				descriptorSetCount = 1,
				pSetLayouts = &pyramid.descriptor_set_layout,
			},
			&descriptor_set,
		)

		// Bind output mip
		output_image_info := vk.DescriptorImageInfo {
			imageView   = pyramid.mip_views[i],
			imageLayout = .GENERAL,
		}

		// Bind input (source depth for mip 0, previous mip for others)
		input_image_info: vk.DescriptorImageInfo
		if i == 0 {
			input_image_info = {
				sampler     = pyramid.sampler,
				imageView   = source_depth_view,
				imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
			}
		} else {
			input_image_info = {
				sampler     = pyramid.sampler,
				imageView   = pyramid.mip_views[i - 1],
				imageLayout = .GENERAL,
			}
		}

		writes := [?]vk.WriteDescriptorSet {
			{
				sType           = .WRITE_DESCRIPTOR_SET,
				dstSet          = descriptor_set,
				dstBinding      = 0,
				descriptorType  = .STORAGE_IMAGE,
				descriptorCount = 1,
				pImageInfo      = &output_image_info,
			},
			{
				sType           = .WRITE_DESCRIPTOR_SET,
				dstSet          = descriptor_set,
				dstBinding      = 1,
				descriptorType  = .COMBINED_IMAGE_SAMPLER,
				descriptorCount = 1,
				pImageInfo      = &input_image_info,
			},
		}

		vk.UpdateDescriptorSets(gpu_context.device, len(writes), raw_data(writes[:]), 0, nil)

		// Bind descriptor set
		vk.CmdBindDescriptorSets(
			cmd,
			.COMPUTE,
			pyramid.pipeline_layout,
			0,
			1,
			&descriptor_set,
			0,
			nil,
		)

		// Push constants
		push := DepthPyramidPushConstants {
			image_size = {f32(mip_width), f32(mip_height)},
			mip_level  = i,
		}

		vk.CmdPushConstants(
			cmd,
			pyramid.pipeline_layout,
			{.COMPUTE},
			0,
			size_of(push),
			&push,
		)

		// Dispatch
		group_x := (mip_width + 31) / 32
		group_y := (mip_height + 31) / 32
		vk.CmdDispatch(cmd, group_x, group_y, 1)

		// Barrier between mip levels
		if i < pyramid.mip_levels - 1 {
			mip_barrier := vk.ImageMemoryBarrier {
				sType               = .IMAGE_MEMORY_BARRIER,
				srcAccessMask       = {.SHADER_WRITE},
				dstAccessMask       = {.SHADER_READ},
				oldLayout           = .GENERAL,
				newLayout           = .GENERAL,
				image               = pyramid.image,
				subresourceRange    = {
					aspectMask     = {.COLOR},
					baseMipLevel   = i,
					levelCount     = 1,
					layerCount     = 1,
				},
			}

			vk.CmdPipelineBarrier(
				cmd,
				{.COMPUTE_SHADER},
				{.COMPUTE_SHADER},
				{},
				0, nil,
				0, nil,
				1, &mip_barrier,
			)
		}
	}

	// Final barrier - ready for sampling in occlusion culling
	final_barrier := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {.SHADER_WRITE},
		dstAccessMask       = {.SHADER_READ},
		oldLayout           = .GENERAL,
		newLayout           = .SHADER_READ_ONLY_OPTIMAL,
		image               = pyramid.image,
		subresourceRange    = {
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = pyramid.mip_levels,
			layerCount     = 1,
		},
	}

	vk.CmdPipelineBarrier(
		cmd,
		{.COMPUTE_SHADER},
		{.COMPUTE_SHADER},
		{},
		0, nil,
		0, nil,
		1, &final_barrier,
	)
}

depth_pyramid_ensure_size :: proc(
        pyramid: ^DepthPyramid,
        gpu_context: ^gpu.GPUContext,
        width, height: u32,
) -> vk.Result {
        desired_width := max(u32(1), previous_pow2(width))
        desired_height := max(u32(1), previous_pow2(height))

        if pyramid.image != 0 && pyramid.width == desired_width && pyramid.height == desired_height {
                return .SUCCESS
        }

        if pyramid.image != 0 {
                depth_pyramid_shutdown(pyramid, gpu_context.device)
        }

        return depth_pyramid_init(pyramid, gpu_context, width, height)
}

// Utility functions

previous_pow2 :: proc(v: u32) -> u32 {
	r := u32(1)
	for r * 2 < v {
		r *= 2
	}
	return r
}

get_mip_levels :: proc(width, height: u32) -> u32 {
	max_dim := max(width, height)
	levels := u32(1)
	dim := max_dim
	for dim > 1 {
		dim >>= 1
		levels += 1
	}
	return levels
}
