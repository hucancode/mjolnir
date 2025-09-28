package resources

import "core:log"
import "core:math"
import "../geometry"
import "../gpu"
import vk "vendor:vulkan"

LightType :: enum u32 {
	POINT       = 0,
	DIRECTIONAL = 1,
	SPOT        = 2,
}

LightData :: struct {
	color:        [4]f32, // RGB + intensity
	radius:       f32,    // range for point/spot lights
	angle_inner:  f32,    // inner cone angle for spot lights (cosine)
	angle_outer:  f32,    // outer cone angle for spot lights (cosine)
	type:         u32,    // LightType
	node_index:   u32,    // index into world matrices buffer
	shadow_map:   u32,    // texture index in bindless array
	camera_index: u32,    // index into camera matrices buffer
	cast_shadow:  b32,    // 0 = no shadow, 1 = cast shadow
}

Light :: struct {
	data:         LightData,
	node_handle:  Handle,     // Associated scene node for transform updates
	light_type:   LightType,  // Type of light
	cast_shadow:  bool,       // Whether this light should cast shadows
	// For spot lights - single render target for shadow mapping
	shadow_render_target: Handle,
	// For point lights - 6 render targets for cube shadow mapping
	cube_render_targets: [6]Handle,
}

// Create a new light and return its handle
create_light :: proc(
	manager: ^Manager,
	gpu_context: ^gpu.GPUContext,
	light_type: LightType,
	node_handle: Handle,
	color: [4]f32 = {1, 1, 1, 1},
	radius: f32 = 10.0,
	angle_inner: f32 = 0.8,
	angle_outer: f32 = 0.9,
	cast_shadow: bool = true,
) -> Handle {
	handle, light := alloc(&manager.lights)
	light.light_type = light_type
	light.node_handle = node_handle
	light.cast_shadow = cast_shadow
	light.data.color = color
	light.data.radius = radius
	light.data.angle_inner = angle_inner
	light.data.angle_outer = angle_outer
	light.data.type = u32(light_type)
	light.data.cast_shadow = b32(cast_shadow)
	light.data.node_index = node_handle.index // Set the node index for transformation

	// Create shadow resources if shadow casting is enabled
	if cast_shadow {
		setup_light_shadow_resources(manager, gpu_context, handle, light)
	}

	sync_light_gpu_data(manager, handle)
	return handle
}

// Destroy a light handle
destroy_light :: proc(
	manager: ^Manager,
	gpu_context: ^gpu.GPUContext,
	handle: Handle,
) -> bool {
	light, ok := get(manager.lights, handle)
	if !ok do return false

	// Destroy shadow resources
	destroy_light_shadow_resources(manager, gpu_context, light)

	_, freed := free(&manager.lights, handle)
	return freed
}

// Get a light by handle
get_light :: proc(
	manager: ^Manager,
	handle: Handle,
) -> (ret: ^Light, ok: bool) #optional_ok {
	ret, ok = get(manager.lights, handle)
	return
}

// Update light data in GPU buffer
sync_light_gpu_data :: proc(
	manager: ^Manager,
	handle: Handle,
) -> bool {
	light, ok := get(manager.lights, handle)
	if !ok do return false
	gpu.write(
		&manager.lights_buffer,
		&light.data,
		int(handle.index),
	)
	return true
}

// Update light color and intensity
set_light_color :: proc(
	manager: ^Manager,
	handle: Handle,
	color: [3]f32,
	intensity: f32,
) {
	if light, ok := get(manager.lights, handle); ok {
		light.data.color = {color.x, color.y, color.z, intensity}
		sync_light_gpu_data(manager, handle)
	}
}

// Update light radius for point/spot lights
set_light_radius :: proc(
	manager: ^Manager,
	handle: Handle,
	radius: f32,
) {
	if light, ok := get(manager.lights, handle); ok {
		light.data.radius = radius
		sync_light_gpu_data(manager, handle)
	}
}

// Update spot light angles
set_spot_light_angles :: proc(
	manager: ^Manager,
	handle: Handle,
	inner_angle: f32,
	outer_angle: f32,
) {
	if light, ok := get(manager.lights, handle); ok {
		light.data.angle_inner = inner_angle
		light.data.angle_outer = outer_angle
		sync_light_gpu_data(manager, handle)
	}
}

// Enable/disable shadow casting
set_light_cast_shadow :: proc(
	manager: ^Manager,
	handle: Handle,
	cast_shadow: bool,
) {
	if light, ok := get(manager.lights, handle); ok {
		light.data.cast_shadow = b32(cast_shadow)
		light.cast_shadow = cast_shadow
		sync_light_gpu_data(manager, handle)
	}
}

// Set shadow render target for spot lights
set_spot_light_shadow_render_target :: proc(
	manager: ^Manager,
	light_handle: Handle,
	render_target_handle: Handle,
) {
	if light, ok := get(manager.lights, light_handle); ok {
		light.shadow_render_target = render_target_handle
		if rt, ok := get(manager.render_targets, render_target_handle); ok {
    		light.data.camera_index = rt.camera.index
		}
	}
}

// Set cube render targets for point lights (one for each face)
set_point_light_cube_render_targets :: proc(
	manager: ^Manager,
	light_handle: Handle,
	render_targets: [6]Handle,
) {
	if light, ok := get(manager.lights, light_handle); ok {
		light.cube_render_targets = render_targets
	}
}

// Update light transform based on node
update_light_transform :: proc(
	manager: ^Manager,
	light_handle: Handle,
) {
	light, light_ok := get(manager.lights, light_handle)
	if !light_ok do return
	light.data.node_index = light.node_handle.index
	sync_light_gpu_data(manager, light_handle)
}

// Update all lights' transform references after world matrices are updated
update_all_light_transforms :: proc(manager: ^Manager) {
	for idx in 0 ..< len(manager.lights.entries) {
		entry := &manager.lights.entries[idx]
		if entry.generation > 0 && entry.active {
			light_handle := Handle{generation = entry.generation, index = u32(idx)}
			light := &entry.item

			// Update the node_index to point to the correct world matrix
			light.data.node_index = light.node_handle.index
			sync_light_gpu_data(manager, light_handle)
		}
	}
}

// Get light data for use in shaders
get_light_data :: proc(
	manager: ^Manager,
	handle: Handle,
) -> (data: ^LightData, ok: bool) #optional_ok {
	light, light_ok := get(manager.lights, handle)
	if !light_ok do return nil, false
	return &light.data, true
}

// Setup shadow resources for a light (called during light creation)
setup_light_shadow_resources :: proc(
	manager: ^Manager,
	gpu_context: ^gpu.GPUContext,
	light_handle: Handle,
	light: ^Light,
) {
	switch light.light_type {
	case .POINT:
		setup_point_light_shadow_resources(manager, gpu_context, light_handle, light)
	case .SPOT:
		setup_spot_light_shadow_resources(manager, gpu_context, light_handle, light)
	case .DIRECTIONAL:
		// Directional shadows not implemented yet
	}
}

// Setup shadow resources for point lights
setup_point_light_shadow_resources :: proc(
	manager: ^Manager,
	gpu_context: ^gpu.GPUContext,
	light_handle: Handle,
	light: ^Light,
) {
	SHADOW_MAP_SIZE :: 512

	// Create cube shadow map texture
	cube_shadow_handle, _, ret := create_empty_texture_cube(
		gpu_context,
		manager,
		SHADOW_MAP_SIZE,
		.D32_SFLOAT,
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
	)
	if ret != .SUCCESS {
		log.errorf("Failed to create cube shadow texture: %v", ret)
		return
	}
	light.data.shadow_map = cube_shadow_handle.index

	// Setup 6 render targets for cube faces (forward=-Z convention)
	// +X, -X, +Y, -Y, +Z, -Z faces
	dirs := [6][3]f32{
		{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
	}
	// Up vectors for each face with forward=-Z convention
	ups := [6][3]f32{
		{0, -1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, -1, 0},
	}

	for face in 0 ..< 6 {
		// Create render target for this face
		render_target_handle, render_target := alloc(&manager.render_targets)

		// Create camera for this face
		camera_handle, camera := alloc(&manager.cameras)
		camera^ = geometry.make_camera_perspective(math.PI * 0.5, 1.0, 0.1, light.data.radius)

		render_target.camera = camera_handle
		render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
		render_target.features = {.DEPTH_TEXTURE}

		// Set depth texture for all frames to the cube shadow map
		for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
			render_target.depth_textures[frame_idx] = cube_shadow_handle
		}

		light.cube_render_targets[face] = render_target_handle
	}
}

// Setup shadow resources for spot lights
setup_spot_light_shadow_resources :: proc(
	manager: ^Manager,
	gpu_context: ^gpu.GPUContext,
	light_handle: Handle,
	light: ^Light,
) {
	SHADOW_MAP_SIZE :: 512

	// Create shadow map texture
	shadow_handle, _, ret := create_empty_texture_2d(
		gpu_context,
		manager,
		SHADOW_MAP_SIZE,
		SHADOW_MAP_SIZE,
		.D32_SFLOAT,
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
	)
	if ret != .SUCCESS {
		log.errorf("Failed to create shadow texture")
		return
	}
	light.data.shadow_map = shadow_handle.index

	// Create render target
	render_target_handle, render_target := alloc(&manager.render_targets)

	// Create camera
	camera_handle, camera := alloc(&manager.cameras)
	fov := light.data.angle_outer * 2.0
	camera^ = geometry.make_camera_perspective(fov, 1.0, 0.1, light.data.radius)

	render_target.camera = camera_handle
	render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
	render_target.features = {.DEPTH_TEXTURE}

	// Set depth texture for all frames
	for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
		render_target.depth_textures[frame_idx] = shadow_handle
	}

	light.shadow_render_target = render_target_handle
	light.data.camera_index = camera_handle.index
}

// Destroy shadow resources for a light
destroy_light_shadow_resources :: proc(
	manager: ^Manager,
	gpu_context: ^gpu.GPUContext,
	light: ^Light,
) {
	if !light.cast_shadow do return

	switch light.light_type {
	case .POINT:
		// Get the cube shadow texture handle before destroying render targets
		cube_texture_handle: Handle
		if light.cube_render_targets[0].generation != 0 {
			if render_target, ok := get(manager.render_targets, light.cube_render_targets[0]); ok {
				if len(render_target.depth_textures) > 0 {
					cube_texture_handle = render_target.depth_textures[0]
				}
			}
		}

		// Destroy cube render targets and their cameras
		for face in 0 ..< 6 {
			if light.cube_render_targets[face].generation != 0 {
				if render_target, ok := free(&manager.render_targets, light.cube_render_targets[face]); ok {
					// Free the camera associated with this render target
					free(&manager.cameras, render_target.camera)
				}
				light.cube_render_targets[face] = {}
			}
		}
		// Free the cube shadow map texture
		if cube_texture_handle.generation != 0 {
			if texture, ok := free(&manager.image_cube_buffers, cube_texture_handle); ok {
				gpu.cube_depth_texture_destroy(gpu_context.device, texture)
			}
		}
	case .SPOT:
		// Get the shadow texture handle before destroying render target
		shadow_texture_handle: Handle
		if light.shadow_render_target.generation != 0 {
			if render_target, ok := get(manager.render_targets, light.shadow_render_target); ok {
				if len(render_target.depth_textures) > 0 {
					shadow_texture_handle = render_target.depth_textures[0]
				}
			}
		}

		// Destroy spot render target and camera
		if light.shadow_render_target.generation != 0 {
			if render_target, ok := free(&manager.render_targets, light.shadow_render_target); ok {
				// Free the camera associated with this render target
				free(&manager.cameras, render_target.camera)
			}
			light.shadow_render_target = {}
		}
		// Free the shadow map texture
		if shadow_texture_handle.generation != 0 {
			if texture, ok := free(&manager.image_2d_buffers, shadow_texture_handle); ok {
				gpu.image_buffer_destroy(gpu_context.device, texture)
			}
		}
	case .DIRECTIONAL:
		// Directional shadows not implemented yet
	}

	light.data.shadow_map = 0
}
