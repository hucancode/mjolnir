package resources

import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

// SphericalCamera captures a full sphere (omnidirectional view) into a cube map
// Used for point light shadows - captures all directions in a single render pass using geometry shader
// Visibility culling is simple: objects within sphere radius are visible
SphericalCamera :: struct {
	center:              [3]f32, // Center position of the sphere
	radius:              f32, // Capture radius
	near:                f32, // Near plane
	far:                 f32, // Far plane
	data:                CameraData, // GPU data for bindless buffer
	size:                u32, // Resolution of cube map faces (size x size)
	depth_cube:          Handle, // Cube depth texture
	command_buffer:      vk.CommandBuffer, // Secondary command buffer
	draw_commands:       gpu.DataBuffer(vk.DrawIndexedIndirectCommand), // Draw commands for visible objects
	draw_count:          gpu.DataBuffer(u32), // Number of visible objects
	max_draws:           u32, // Maximum number of draw calls
	descriptor_set:      vk.DescriptorSet, // Descriptor set for sphere culling compute shader
}

// Initialize a new spherical camera
spherical_camera_init :: proc(
	camera: ^SphericalCamera,
	gpu_context: ^gpu.GPUContext,
	manager: ^Manager,
	size: u32 = SHADOW_MAP_SIZE,
	center: [3]f32 = {0, 0, 0},
	radius: f32 = 10.0,
	near: f32 = 0.1,
	far: f32 = 100.0,
	depth_format: vk.Format = .D32_SFLOAT,
	max_draws: u32 = MAX_NODES_IN_SCENE,
) -> vk.Result {
	camera.center = center
	camera.radius = radius
	camera.near = near
	camera.far = far
	camera.size = size
	camera.max_draws = max_draws

	// Create cube depth map
	camera.depth_cube, _, _ = create_empty_texture_cube(
		gpu_context,
		manager,
		size,
		depth_format,
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
	)

	// Allocate command buffer
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = gpu_context.command_pool,
		level              = .SECONDARY,
		commandBufferCount = 1,
	}
	vk.AllocateCommandBuffers(
		gpu_context.device,
		&alloc_info,
		&camera.command_buffer,
	) or_return

	camera.draw_count = gpu.create_host_visible_buffer(
		gpu_context,
		u32,
		1,
		{.STORAGE_BUFFER, .TRANSFER_DST},
	) or_return

	camera.draw_commands = gpu.create_host_visible_buffer(
		gpu_context,
		vk.DrawIndexedIndirectCommand,
		int(max_draws),
		{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
	) or_return

	// Allocate visibility descriptors
	spherical_camera_allocate_visibility_descriptors(
		gpu_context,
		manager,
		camera,
		&manager.visibility_sphere_descriptor_layout,
	) or_return

	return .SUCCESS
}

// Destroy spherical camera and release all resources
spherical_camera_destroy :: proc(
	camera: ^SphericalCamera,
	device: vk.Device,
	command_pool: vk.CommandPool,
	manager: ^Manager,
) {
	// Free camera-owned cube depth texture
	if camera.depth_cube.generation > 0 {
		if item, freed := free(&manager.image_cube_buffers, camera.depth_cube); freed {
			gpu.cube_depth_texture_destroy(device, item)
		}
	}

	// Free command buffer
	vk.FreeCommandBuffers(device, command_pool, 1, &camera.command_buffer)

	// Free buffers
	gpu.data_buffer_destroy(device, &camera.draw_count)
	gpu.data_buffer_destroy(device, &camera.draw_commands)
}

// Update spherical camera position and parameters
spherical_camera_set_position :: proc(camera: ^SphericalCamera, center: [3]f32) {
	camera.center = center
}

spherical_camera_set_radius :: proc(camera: ^SphericalCamera, radius: f32) {
	camera.radius = radius
	camera.far = radius // Update far plane to match radius
}

spherical_camera_set_near_far :: proc(camera: ^SphericalCamera, near, far: f32) {
	camera.near = near
	camera.far = far
}

// Upload camera data to GPU buffer
// For spherical camera, we store 6 projection matrices (one for each cube face)
// TODO: fix this, rework spherical camera data
spherical_camera_upload_data :: proc(
	manager: ^Manager,
	camera: ^SphericalCamera,
	camera_index: u32,
) {
	dst := gpu.data_buffer_get(&manager.spherical_camera_buffer, camera_index)
	if dst == nil {
		log.errorf("Spherical camera index %d out of bounds", camera_index)
		return
	}

	// Spherical camera uses identity view (transformations happen in geometry shader)
	// Geometry shader will apply per-face view matrices
	dst.view = linalg.MATRIX4F32_IDENTITY

	// Perspective projection with 90° FOV for cube map faces
	fov := f32(math.PI * 0.5) // 90 degrees
	aspect := f32(1.0) // Square faces
	dst.projection = linalg.matrix4_perspective(fov, aspect, camera.near, camera.far)

	// Store sphere parameters
	dst.viewport_params = [4]f32 {
		f32(camera.size),
		f32(camera.size),
		camera.near,
		camera.far,
	}

	// Store center position and radius
	dst.position = [4]f32 {
		camera.center[0],
		camera.center[1],
		camera.center[2],
		camera.radius, // Store radius in w component
	}
	camera.data = dst^
}

// Simple radius-based visibility culling
// Returns true if an AABB is within the sphere radius
spherical_camera_test_aabb :: proc(camera: ^SphericalCamera, aabb_min, aabb_max: [3]f32) -> bool {
	// Find the closest point on AABB to sphere center
	closest: [3]f32
	for i in 0 ..< 3 {
		closest[i] = max(aabb_min[i], min(camera.center[i], aabb_max[i]))
	}

	// Check if closest point is within sphere radius
	distance_sq := linalg.length2(closest - camera.center)
	return distance_sq <= camera.radius * camera.radius
}

// Get visible object count
spherical_camera_get_visible_count :: proc(camera: ^SphericalCamera) -> u32 {
	if camera.draw_count.mapped == nil do return 0
	return camera.draw_count.mapped[0]
}

// Allocate and update descriptor set for sphere culling compute shader
// This should be called AFTER spherical_camera_init and requires the visibility system's sphere descriptor layout
spherical_camera_allocate_visibility_descriptors :: proc(
	gpu_context: ^gpu.GPUContext,
	manager: ^Manager,
	camera: ^SphericalCamera,
	sphere_descriptor_layout: ^vk.DescriptorSetLayout,
) -> vk.Result {
	// Allocate sphere culling descriptor set
	vk.AllocateDescriptorSets(
		gpu_context.device,
		&vk.DescriptorSetAllocateInfo {
			sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = gpu_context.descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts = sphere_descriptor_layout,
		},
		&camera.descriptor_set,
	) or_return

	// Update descriptor set
	spherical_camera_update_descriptor_set(gpu_context, manager, camera)

	return .SUCCESS
}

// Update sphere culling descriptor set with current buffer bindings
@(private)
spherical_camera_update_descriptor_set :: proc(
	gpu_context: ^gpu.GPUContext,
	manager: ^Manager,
	camera: ^SphericalCamera,
) {
	node_info := vk.DescriptorBufferInfo {
		buffer = manager.node_data_buffer.device_buffer,
		range = vk.DeviceSize(manager.node_data_buffer.bytes_count),
	}
	mesh_info := vk.DescriptorBufferInfo {
		buffer = manager.mesh_data_buffer.device_buffer,
		range = vk.DeviceSize(manager.mesh_data_buffer.bytes_count),
	}
	world_info := vk.DescriptorBufferInfo {
		buffer = manager.world_matrix_buffer.device_buffer,
		range = vk.DeviceSize(manager.world_matrix_buffer.bytes_count),
	}
	camera_info := vk.DescriptorBufferInfo {
		buffer = manager.spherical_camera_buffer.buffer,
		range = vk.DeviceSize(manager.spherical_camera_buffer.bytes_count),
	}
	count_info := vk.DescriptorBufferInfo {
		buffer = camera.draw_count.buffer,
		range = vk.DeviceSize(camera.draw_count.bytes_count),
	}
	command_info := vk.DescriptorBufferInfo {
		buffer = camera.draw_commands.buffer,
		range = vk.DeviceSize(camera.draw_commands.bytes_count),
	}

	// NOTE: Bindings must match sphere_cull.comp shader!
	// Binding 4 is skipped (no depth pyramid in sphere culling)
	// Bindings 5,6 are for draw count/commands to match the shader layout
	writes := [?]vk.WriteDescriptorSet {
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = camera.descriptor_set, dstBinding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &node_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = camera.descriptor_set, dstBinding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &mesh_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = camera.descriptor_set, dstBinding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &world_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = camera.descriptor_set, dstBinding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &camera_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = camera.descriptor_set, dstBinding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &count_info},    // Binding 5!
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = camera.descriptor_set, dstBinding = 6, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &command_info},  // Binding 6!
	}

	vk.UpdateDescriptorSets(gpu_context.device, len(writes), raw_data(writes[:]), 0, nil)
}
