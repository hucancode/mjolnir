package mjolnir

import linalg "core:math/linalg"
import vk "vendor:vulkan"
import "geometry"

Particle :: struct {
  position:    linalg.Vector3f32,
  size:        f32,
  velocity:    linalg.Vector3f32,
  lifetime:    f32,
  color_start: linalg.Vector4f32,
  color_end:   linalg.Vector4f32,
}

// --- Vulkan Compute Pipeline Setup for Particles ---
ParticleComputePipeline :: struct {
    particle_buffer: DataBuffer(Particle),
    params_buffer:   DataBuffer(f32), // Only deltaTime for now
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_set: vk.DescriptorSet,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
}

setup_particle_compute_pipeline :: proc(
    max_particles: int,
) -> (pipeline: ParticleComputePipeline, ret: vk.Result) {

    // 1. Create particle buffer (storage buffer)
    pipeline.particle_buffer = create_host_visible_buffer(
        Particle,
        max_particles,
        {.STORAGE_BUFFER},
    ) or_return

    // 2. Create params buffer (uniform buffer)
    pipeline.params_buffer = create_host_visible_buffer(
        f32,
        1,
        {.UNIFORM_BUFFER},
    ) or_return

    // 3. Descriptor set layout
    bindings := [?]vk.DescriptorSetLayoutBinding {
        {
            binding = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            stageFlags = {.COMPUTE},
        },
        {
            binding = 1,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            stageFlags = {.COMPUTE},
        },
    }
    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = len(bindings),
        pBindings = raw_data(bindings[:]),
    }
    vk.CreateDescriptorSetLayout(g_device, &layout_info, nil, &pipeline.descriptor_set_layout) or_return

    // 4. Descriptor set allocation and update
    vk.AllocateDescriptorSets(
        g_device,
        &vk.DescriptorSetAllocateInfo {
            sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool = g_descriptor_pool,
            descriptorSetCount = 1,
            pSetLayouts = &pipeline.descriptor_set_layout,
        },
        &pipeline.descriptor_set,
    ) or_return

    particle_buffer_info := vk.DescriptorBufferInfo {
        buffer = pipeline.particle_buffer.buffer,
        offset = 0,
        range  = vk.DeviceSize(pipeline.particle_buffer.bytes_count),
    }
    params_buffer_info := vk.DescriptorBufferInfo {
        buffer = pipeline.params_buffer.buffer,
        offset = 0,
        range  = size_of(f32),
    }
    writes := [?]vk.WriteDescriptorSet {
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = pipeline.descriptor_set,
            dstBinding = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &particle_buffer_info,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = pipeline.descriptor_set,
            dstBinding = 1,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &params_buffer_info,
        },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)

    // 5. Pipeline layout and compute pipeline
    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &pipeline.descriptor_set_layout,
    }
    vk.CreatePipelineLayout(g_device, &pipeline_layout_info, nil, &pipeline.pipeline_layout) or_return

    shader_module := create_shader_module(#load("shader/particle/compute.spv")) or_return

    pipeline_info := vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        stage = vk.PipelineShaderStageCreateInfo {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.COMPUTE},
            module = shader_module,
            pName = "main",
        },
        layout = pipeline.pipeline_layout,
    }
    vk.CreateComputePipelines(g_device, 0, 1, &pipeline_info, nil, &pipeline.pipeline) or_return
    ret = .SUCCESS
    return
}

// --- Per-frame usage ---
// 1. Write deltaTime to params_buffer
//    data_buffer_write(pipeline.params_buffer, &delta_time)
// 2. Bind pipeline and descriptor set, dispatch compute
//    vk.CmdBindPipeline(cmd_buf, .COMPUTE, pipeline.pipeline)
//    vk.CmdBindDescriptorSets(cmd_buf, .COMPUTE, pipeline.pipeline_layout, 0, 1, &pipeline.descriptor_set, 0, nil)
//    vk.CmdDispatch(cmd_buf, (max_particles + 255) / 256, 1, 1)
// 3. Insert buffer memory barrier before graphics
//    barrier := vk.BufferMemoryBarrier {
//        srcAccessMask = .SHADER_WRITE,
//        dstAccessMask = .VERTEX_ATTRIBUTE_READ,
//        buffer = pipeline.particle_buffer.buffer,
//        offset = 0,
//        size = VK_WHOLE_SIZE,
//    }
//    vk.CmdPipelineBarrier(
//        cmd_buf,
//        .COMPUTE_SHADER,
//        .VERTEX_INPUT,
//        {},
//        0, nil,
//        1, &barrier,
//        0, nil,
//    )

Emitter :: struct {
  transform:         geometry.Transform,
  emission_rate:     f32, // Particles per second
  particle_lifetime: f32,
  initial_velocity:  linalg.Vector3f32,
  velocity_spread:   f32,
  color_start:       linalg.Vector4f32, // Start color (RGBA)
  color_end:         linalg.Vector4f32, // End color (RGBA)
  size_start:        f32,
  size_end:          f32,
  enabled:           bool,
  time_accumulator:  f32,
}
