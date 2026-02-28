package render

import rg "graph"
import alg "../algebra"
import rd "data"
import "../gpu"
import vk "vendor:vulkan"
import "core:slice"
import "core:log"

// Import render modules used in execute callbacks
import "geometry"
import "ambient"
import "direct_light"
import "transparent"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import ui_render "ui"
import "debug_ui"
import depth_pyramid_system "depth_pyramid"
import "occlusion_culling"
import shadow_culling_system "shadow_culling"
import shadow_render_system "shadow_render"
import shadow_sphere_culling_system "shadow_sphere_culling"
import shadow_sphere_render_system "shadow_sphere_render"

// ============================================================================
// Frame Graph Pass Implementations
// All setup/execute callbacks for the 13 frame graph passes
// ============================================================================

// ============================================================================
// GEOMETRY PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

geometry_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Register external G-buffer textures (Manager-owned in Phase 1)
	position_tex := rg.register_external_texture(
		setup,
		"gbuffer_position",
		rg.TextureDesc{
			width = 1920, height = 1080, // Placeholder, will be populated from actual resources
			format = .R32G32B32A32_SFLOAT,
			usage = {.COLOR_ATTACHMENT, .SAMPLED},
			aspect = {.COLOR},
			is_external = true,
		},
	)
	normal_tex := rg.register_external_texture(
		setup,
		"gbuffer_normal",
		rg.TextureDesc{
			width = 1920, height = 1080,
			format = .R16G16B16A16_SFLOAT,
			usage = {.COLOR_ATTACHMENT, .SAMPLED},
			aspect = {.COLOR},
			is_external = true,
		},
	)
	albedo_tex := rg.register_external_texture(
		setup,
		"gbuffer_albedo",
		rg.TextureDesc{
			width = 1920, height = 1080,
			format = .R8G8B8A8_SRGB,
			usage = {.COLOR_ATTACHMENT, .SAMPLED},
			aspect = {.COLOR},
			is_external = true,
		},
	)
	metallic_roughness_tex := rg.register_external_texture(
		setup,
		"gbuffer_metallic_roughness",
		rg.TextureDesc{
			width = 1920, height = 1080,
			format = .R8G8B8A8_UNORM,
			usage = {.COLOR_ATTACHMENT, .SAMPLED},
			aspect = {.COLOR},
			is_external = true,
		},
	)
	emissive_tex := rg.register_external_texture(
		setup,
		"gbuffer_emissive",
		rg.TextureDesc{
			width = 1920, height = 1080,
			format = .R16G16B16A16_SFLOAT,
			usage = {.COLOR_ATTACHMENT, .SAMPLED},
			aspect = {.COLOR},
			is_external = true,
		},
	)
	final_image_tex := rg.register_external_texture(
		setup,
		"final_image",
		rg.TextureDesc{
			width = 1920, height = 1080,
			format = .R16G16B16A16_SFLOAT,
			usage = {.COLOR_ATTACHMENT, .SAMPLED},
			aspect = {.COLOR},
			is_external = true,
		},
	)
	depth_tex := rg.register_external_texture(
		setup,
		"depth",
		rg.TextureDesc{
			width = 1920, height = 1080,
			format = .D32_SFLOAT,
			usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
			aspect = {.DEPTH},
			is_external = true,
		},
	)

	// Register external draw command buffers
	opaque_cmds := rg.register_external_buffer(
		setup,
		"opaque_draw_commands",
		rg.BufferDesc{
			size = 1024 * 1024,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)
	opaque_count := rg.register_external_buffer(
		setup,
		"opaque_draw_count",
		rg.BufferDesc{
			size = 4,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)

	// Declare dependencies
	rg.read_buffer(setup, opaque_cmds, .CURRENT)
	rg.read_buffer(setup, opaque_count, .CURRENT)
	rg.write_texture(setup, position_tex, .CURRENT)
	rg.write_texture(setup, normal_tex, .CURRENT)
	rg.write_texture(setup, albedo_tex, .CURRENT)
	rg.write_texture(setup, metallic_roughness_tex, .CURRENT)
	rg.write_texture(setup, emissive_tex, .CURRENT)
	rg.write_texture(setup, final_image_tex, .CURRENT)
	rg.write_texture(setup, depth_tex, .CURRENT)
}

geometry_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	// Call existing render function
	geometry.begin_pass(
		cam.attachments[.POSITION][frame_index],
		cam.attachments[.NORMAL][frame_index],
		cam.attachments[.ALBEDO][frame_index],
		cam.attachments[.METALLIC_ROUGHNESS][frame_index],
		cam.attachments[.EMISSIVE][frame_index],
		cam.attachments[.FINAL_IMAGE][frame_index],
		cam.attachments[.DEPTH][frame_index],
		&manager.texture_manager,
		cmd,
	)
	geometry.render(
		&manager.geometry,
		cam_handle,
		cmd,
		manager.camera_buffer.descriptor_sets[frame_index],
		manager.texture_manager.descriptor_set,
		manager.bone_buffer.descriptor_sets[frame_index],
		manager.material_buffer.descriptor_set,
		manager.node_data_buffer.descriptor_set,
		manager.mesh_data_buffer.descriptor_set,
		manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
		manager.mesh_manager.vertex_buffer.buffer,
		manager.mesh_manager.index_buffer.buffer,
		cam.opaque_draw_commands[frame_index].buffer,
		cam.opaque_draw_count[frame_index].buffer,
	)
	geometry.end_pass(
		cam.attachments[.POSITION][frame_index],
		cam.attachments[.NORMAL][frame_index],
		cam.attachments[.ALBEDO][frame_index],
		cam.attachments[.METALLIC_ROUGHNESS][frame_index],
		cam.attachments[.EMISSIVE][frame_index],
		cam.attachments[.DEPTH][frame_index],
		&manager.texture_manager,
		cmd,
	)
}

// ============================================================================
// AMBIENT PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

ambient_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find G-buffer resources created by geometry pass
	position_tex, ok1 := rg.find_texture(setup, "gbuffer_position")
	normal_tex, ok2 := rg.find_texture(setup, "gbuffer_normal")
	albedo_tex, ok3 := rg.find_texture(setup, "gbuffer_albedo")
	metallic_roughness_tex, ok4 := rg.find_texture(setup, "gbuffer_metallic_roughness")
	emissive_tex, ok5 := rg.find_texture(setup, "gbuffer_emissive")
	final_image_tex, ok6 := rg.find_texture(setup, "final_image")

	// Validate resources were found
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 {
		log.errorf("ambient_setup (cam %d): Failed to find G-buffer resources!", setup.instance_idx)
		return
	}

	// Declare dependencies - read G-buffer, write to final image
	rg.read_texture(setup, position_tex, .CURRENT)
	rg.read_texture(setup, normal_tex, .CURRENT)
	rg.read_texture(setup, albedo_tex, .CURRENT)
	rg.read_texture(setup, metallic_roughness_tex, .CURRENT)
	rg.read_texture(setup, emissive_tex, .CURRENT)
	rg.read_write_texture(setup, final_image_tex, .CURRENT)
}

ambient_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	ambient.begin_pass(
		&manager.ambient,
		cam.attachments[.FINAL_IMAGE][frame_index],
		&manager.texture_manager,
		cmd,
		manager.camera_buffer.descriptor_sets[frame_index],
	)
	ambient.render(
		&manager.ambient,
		cam_handle,
		cam.attachments[.POSITION][frame_index].index,
		cam.attachments[.NORMAL][frame_index].index,
		cam.attachments[.ALBEDO][frame_index].index,
		cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
		cam.attachments[.EMISSIVE][frame_index].index,
		cmd,
	)
	ambient.end_pass(cmd)
}

// ============================================================================
// DIRECT_LIGHT PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

direct_light_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find G-buffer resources (created by geometry pass in same scope)
	position_tex, ok1 := rg.find_texture(setup, "gbuffer_position")
	normal_tex, ok2 := rg.find_texture(setup, "gbuffer_normal")
	albedo_tex, ok3 := rg.find_texture(setup, "gbuffer_albedo")
	metallic_roughness_tex, ok4 := rg.find_texture(setup, "gbuffer_metallic_roughness")
	final_image_tex, ok5 := rg.find_texture(setup, "final_image")
	depth_tex, ok6 := rg.find_texture(setup, "depth")

	// Validate resources were found
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 {
		log.errorf("direct_light_setup (cam %d): Failed to find G-buffer resources!", setup.instance_idx)
		log.errorf("  position: %v, normal: %v, albedo: %v, mr: %v, final: %v, depth: %v",
			ok1, ok2, ok3, ok4, ok5, ok6)
		return
	}

	// Declare dependencies
	rg.read_texture(setup, position_tex, .CURRENT)
	rg.read_texture(setup, normal_tex, .CURRENT)
	rg.read_texture(setup, albedo_tex, .CURRENT)
	rg.read_texture(setup, metallic_roughness_tex, .CURRENT)
	rg.read_texture(setup, depth_tex, .CURRENT)
	rg.read_write_texture(setup, final_image_tex, .CURRENT)

	// Read shadow maps from all lights - creates execution dependency on shadow_render passes
	for light_idx in 0..<u32(len(manager.per_light_data)) {
		if shadow_2d, ok := rg.find_texture_in_scope(setup, "shadow_map_2d", .PER_LIGHT, light_idx); ok {
			rg.read_texture(setup, shadow_2d, .CURRENT)
		}
		if shadow_cube, ok := rg.find_texture_in_scope(setup, "shadow_map_cube", .PER_LIGHT, light_idx); ok {
			rg.read_texture(setup, shadow_cube, .CURRENT)
		}
	}
}

direct_light_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	direct_light.begin_pass(
		&manager.direct_light,
		cam.attachments[.FINAL_IMAGE][frame_index],
		cam.attachments[.DEPTH][frame_index],
		&manager.texture_manager,
		cmd,
		manager.camera_buffer.descriptor_sets[frame_index],
	)

	// Render all lights in sorted order
	light_node_indices := make([dynamic]u32, 0, len(manager.per_light_data), context.temp_allocator)
	for light_node_index in manager.per_light_data {
		append(&light_node_indices, light_node_index)
	}
	slice.sort(light_node_indices[:])

	for light_node_index in light_node_indices {
		light_data := &manager.per_light_data[light_node_index]
		if light_data.light_index >= rd.MAX_LIGHTS do continue

		switch &variant in &light_data.light {
		case PointLight:
			shadow_map_idx: u32 = 0xFFFFFFFF
			shadow_view_projection := matrix[4, 4]f32{}
			if variant.shadow != nil {
				sm := variant.shadow.?
				shadow_map_idx = sm.shadow_map_cube[frame_index].index
				shadow_view_projection = sm.projection
			}
			direct_light.render_point_light(
				&manager.direct_light,
				cam_handle,
				cam.attachments[.POSITION][frame_index].index,
				cam.attachments[.NORMAL][frame_index].index,
				cam.attachments[.ALBEDO][frame_index].index,
				cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
				variant.color,
				variant.position,
				variant.radius,
				shadow_map_idx,
				shadow_view_projection,
				cmd,
			)
		case SpotLight:
			shadow_map_idx: u32 = 0xFFFFFFFF
			shadow_view_projection := matrix[4, 4]f32{}
			if variant.shadow != nil {
				sm := variant.shadow.?
				shadow_map_idx = sm.shadow_map_2d[frame_index].index
				shadow_view_projection = sm.view_projection
			}
			direct_light.render_spot_light(
				&manager.direct_light,
				cam_handle,
				cam.attachments[.POSITION][frame_index].index,
				cam.attachments[.NORMAL][frame_index].index,
				cam.attachments[.ALBEDO][frame_index].index,
				cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
				variant.color,
				variant.position,
				variant.direction,
				variant.radius,
				variant.angle_inner,
				variant.angle_outer,
				shadow_map_idx,
				shadow_view_projection,
				cmd,
			)
		case DirectionalLight:
			shadow_map_idx: u32 = 0xFFFFFFFF
			shadow_view_projection := matrix[4, 4]f32{}
			if variant.shadow != nil {
				sm := variant.shadow.?
				shadow_map_idx = sm.shadow_map_2d[frame_index].index
				shadow_view_projection = sm.view_projection
			}
			direct_light.render_directional_light(
				&manager.direct_light,
				cam_handle,
				cam.attachments[.POSITION][frame_index].index,
				cam.attachments[.NORMAL][frame_index].index,
				cam.attachments[.ALBEDO][frame_index].index,
				cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
				variant.color,
				variant.direction,
				shadow_map_idx,
				shadow_view_projection,
				cmd,
			)
		}
	}

	direct_light.end_pass(cmd)
}

// ============================================================================
// PARTICLES COMPUTE PASS (GLOBAL, COMPUTE)
// ============================================================================

particles_compute_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Register external particle buffers
	particle_buf := rg.register_external_buffer(
		setup,
		"particle_buffer",
		rg.BufferDesc{
			size = 1024 * 1024,
			usage = {.STORAGE_BUFFER},
			is_external = true,
		},
	)
	compact_buf := rg.register_external_buffer(
		setup,
		"compact_particle_buffer",
		rg.BufferDesc{
			size = 1024 * 1024,
			usage = {.STORAGE_BUFFER},
			is_external = true,
		},
	)
	draw_cmd_buf := rg.register_external_buffer(
		setup,
		"particle_draw_command_buffer",
		rg.BufferDesc{
			size = 1024,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)

	// Particle compute writes to buffers
	rg.write_buffer(setup, particle_buf, .CURRENT)
	rg.write_buffer(setup, compact_buf, .CURRENT)
	rg.write_buffer(setup, draw_cmd_buf, .CURRENT)
}

particles_compute_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data

	particles_compute.simulate(
		&manager.particles_compute,
		cmd,
		manager.node_data_buffer.descriptor_set,
		manager.particle_buffer.buffer,
		manager.compact_particle_buffer.buffer,
		manager.particle_draw_command_buffer.buffer,
		vk.DeviceSize(manager.particle_buffer.bytes_count),
	)
}

// ============================================================================
// DEPTH PYRAMID PASS (PER_CAMERA, COMPUTE)
// ============================================================================

depth_pyramid_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find depth texture from geometry pass
	depth_tex, ok := rg.find_texture(setup, "depth")
	if !ok {
		// Depth pyramid requires depth buffer - if not found, skip this pass instance
		return
	}

	// Register external depth pyramid resources
	// (These are complex mip-mapped resources in Phase 1)

	// Read depth texture
	rg.read_texture(setup, depth_tex, .CURRENT)
}

depth_pyramid_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists || !cam.enable_culling do return

	depth_pyramid_system.build_pyramid(
		&manager.depth_pyramid,
		cmd,
		&cam.depth_pyramid[frame_index],
		cam.depth_reduce_descriptor_sets[frame_index][:],
	)
}

// ============================================================================
// OCCLUSION CULLING PASS (PER_CAMERA, COMPUTE)
// ============================================================================

occlusion_culling_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Register external draw command buffers
	opaque_cmds := rg.register_external_buffer(
		setup,
		"opaque_draw_commands",
		rg.BufferDesc{
			size = 1024 * 1024,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)
	opaque_count := rg.register_external_buffer(
		setup,
		"opaque_draw_count",
		rg.BufferDesc{
			size = 4,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)

	transparent_cmds := rg.register_external_buffer(
		setup,
		"transparent_draw_commands",
		rg.BufferDesc{
			size = 1024 * 1024,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)
	transparent_count := rg.register_external_buffer(
		setup,
		"transparent_draw_count",
		rg.BufferDesc{
			size = 4,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)

	// Culling writes to NEXT frame (frame N prepares data for frame N+1)
	rg.write_buffer(setup, opaque_cmds, .NEXT)
	rg.write_buffer(setup, opaque_count, .NEXT)
	rg.write_buffer(setup, transparent_cmds, .NEXT)
	rg.write_buffer(setup, transparent_count, .NEXT)
}

occlusion_culling_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists || !cam.enable_culling do return

	next_frame_index := alg.next(frame_index, rd.FRAMES_IN_FLIGHT)
	prev_frame := alg.prev(next_frame_index, FRAMES_IN_FLIGHT)

	occlusion_culling.perform_culling(
		&manager.visibility,
		cmd,
		cam_handle,
		next_frame_index,
		&cam.opaque_draw_count[next_frame_index],
		&cam.transparent_draw_count[next_frame_index],
		&cam.sprite_draw_count[next_frame_index],
		&cam.wireframe_draw_count[next_frame_index],
		&cam.random_color_draw_count[next_frame_index],
		&cam.line_strip_draw_count[next_frame_index],
		cam.descriptor_set[next_frame_index],
		cam.depth_pyramid[prev_frame].width,
		cam.depth_pyramid[prev_frame].height,
	)
}

// ============================================================================
// SHADOW CULLING PASS (PER_LIGHT, COMPUTE)
// ============================================================================

shadow_culling_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// TODO: Ideally we'd check light type here, but we can't access light_data with instance_idx
	// For now, register shadow resources for all lights (they all use the same resource names)
	shadow_draw_cmds := rg.register_external_buffer(
		setup,
		"shadow_draw_commands",
		rg.BufferDesc{
			size = 1024 * 1024,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)
	shadow_draw_count := rg.register_external_buffer(
		setup,
		"shadow_draw_count",
		rg.BufferDesc{
			size = 4,
			usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
			is_external = true,
		},
	)

	rg.write_buffer(setup, shadow_draw_cmds, .CURRENT)
	rg.write_buffer(setup, shadow_draw_count, .CURRENT)
}

shadow_culling_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	light_index := resources.light_handle
	light_data, exists := &manager.per_light_data[light_index]
	if !exists do return

	// Execute appropriate culling based on light type
	switch &variant in &light_data.light {
	case SpotLight:
		shadow, ok := variant.shadow.?
		if !ok do return

		shadow_culling_system.execute(
			&manager.shadow_culling,
			cmd,
			shadow.frustum_planes,
			shadow.draw_count[frame_index].buffer,
			shadow.descriptor_sets[frame_index],
		)

	case DirectionalLight:
		shadow, ok := variant.shadow.?
		if !ok do return

		shadow_culling_system.execute(
			&manager.shadow_culling,
			cmd,
			shadow.frustum_planes,
			shadow.draw_count[frame_index].buffer,
			shadow.descriptor_sets[frame_index],
		)

	case PointLight:
		shadow, ok := variant.shadow.?
		if !ok do return

		shadow_sphere_culling_system.execute(
			&manager.shadow_sphere_culling,
			cmd,
			variant.position,
			variant.radius,
			shadow.draw_count[frame_index].buffer,
			shadow.descriptor_sets[frame_index],
		)
	}
}

// ============================================================================
// SHADOW RENDER PASS (PER_LIGHT, GRAPHICS)
// ============================================================================

shadow_render_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find shadow draw buffers from culling pass
	shadow_draw_cmds, _ := rg.find_buffer(setup, "shadow_draw_commands")
	shadow_draw_count, _ := rg.find_buffer(setup, "shadow_draw_count")

	// Map sequential instance_idx to actual light handle
	actual_handle := get_light_handle_by_index(manager, setup.instance_idx)
	light_data, exists := manager.per_light_data[actual_handle]

	is_point_light := false
	if exists {
		_, is_point_light = light_data.light.(PointLight)
	}

	// Register write to appropriate shadow map type
	rg.read_buffer(setup, shadow_draw_cmds, .CURRENT)
	rg.read_buffer(setup, shadow_draw_count, .CURRENT)

	if is_point_light {
		shadow_map := rg.register_external_texture(
			setup,
			"shadow_map_cube",
			rg.TextureDesc{
				width = 512, height = 512,
				format = .D32_SFLOAT,
				usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
				aspect = {.DEPTH},
				is_cube = true,
				is_external = true,
			},
		)
		rg.write_texture(setup, shadow_map, .CURRENT)
	} else {
		shadow_map := rg.register_external_texture(
			setup,
			"shadow_map_2d",
			rg.TextureDesc{
				width = 2048, height = 2048,
				format = .D32_SFLOAT,
				usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
				aspect = {.DEPTH},
				is_external = true,
			},
		)
		rg.write_texture(setup, shadow_map, .CURRENT)
	}
}

shadow_render_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	light_index := resources.light_handle
	light_data, exists := &manager.per_light_data[light_index]
	if !exists do return

	// Execute appropriate rendering based on light type
	switch &variant in &light_data.light {
	case SpotLight:
		shadow, ok := variant.shadow.?
		if !ok do return

		shadow_render_system.render(
			&manager.shadow_render,
			cmd,
			&manager.texture_manager,
			shadow.view_projection,
			shadow.shadow_map_2d[frame_index],
			shadow.draw_commands[frame_index],
			shadow.draw_count[frame_index],
			manager.texture_manager.descriptor_set,
			manager.bone_buffer.descriptor_sets[frame_index],
			manager.material_buffer.descriptor_set,
			manager.node_data_buffer.descriptor_set,
			manager.mesh_data_buffer.descriptor_set,
			manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
			manager.mesh_manager.vertex_buffer.buffer,
			manager.mesh_manager.index_buffer.buffer,
			frame_index,
		)

	case DirectionalLight:
		shadow, ok := variant.shadow.?
		if !ok do return

		shadow_render_system.render(
			&manager.shadow_render,
			cmd,
			&manager.texture_manager,
			shadow.view_projection,
			shadow.shadow_map_2d[frame_index],
			shadow.draw_commands[frame_index],
			shadow.draw_count[frame_index],
			manager.texture_manager.descriptor_set,
			manager.bone_buffer.descriptor_sets[frame_index],
			manager.material_buffer.descriptor_set,
			manager.node_data_buffer.descriptor_set,
			manager.mesh_data_buffer.descriptor_set,
			manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
			manager.mesh_manager.vertex_buffer.buffer,
			manager.mesh_manager.index_buffer.buffer,
			frame_index,
		)

	case PointLight:
		shadow, ok := variant.shadow.?
		if !ok do return

		shadow_sphere_render_system.render(
			&manager.shadow_sphere_render,
			cmd,
			&manager.texture_manager,
			shadow.projection,
			shadow.near,
			shadow.far,
			variant.position,
			shadow.shadow_map_cube[frame_index],
			shadow.draw_commands[frame_index],
			shadow.draw_count[frame_index],
			manager.texture_manager.descriptor_set,
			manager.bone_buffer.descriptor_sets[frame_index],
			manager.material_buffer.descriptor_set,
			manager.node_data_buffer.descriptor_set,
			manager.mesh_data_buffer.descriptor_set,
			manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
			manager.mesh_manager.vertex_buffer.buffer,
			manager.mesh_manager.index_buffer.buffer,
			frame_index,
		)
	}
}

// ============================================================================
// PARTICLES RENDER PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

particles_render_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find resources from previous passes
	final_image_tex, ok1 := rg.find_texture(setup, "final_image")
	depth_tex, ok2 := rg.find_texture(setup, "depth")

	// Find particle buffers from compute pass
	compact_buf, ok3 := rg.find_buffer(setup, "compact_particle_buffer")
	draw_cmd_buf, ok4 := rg.find_buffer(setup, "particle_draw_command_buffer")

	if !ok1 || !ok2 || !ok3 || !ok4 {
		// Particle rendering requires these resources
		return
	}

	// Declare dependencies
	rg.read_buffer(setup, compact_buf, .CURRENT)
	rg.read_buffer(setup, draw_cmd_buf, .CURRENT)
	rg.read_write_texture(setup, final_image_tex, .CURRENT)
	rg.read_write_texture(setup, depth_tex, .CURRENT)
}

particles_render_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	particles_render.begin_pass(
		&manager.particles_render,
		cmd,
		cam.attachments[.FINAL_IMAGE][frame_index],
		cam.attachments[.DEPTH][frame_index],
		&manager.texture_manager,
	)
	particles_render.render(
		&manager.particles_render,
		cmd,
		cam_handle,
		manager.camera_buffer.descriptor_sets[frame_index],
		manager.texture_manager.descriptor_set,
		manager.compact_particle_buffer.buffer,
		manager.particle_draw_command_buffer.buffer,
	)
	particles_render.end_pass(cmd)
}

// ============================================================================
// TRANSPARENT PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

transparent_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find resources
	final_image_tex, ok1 := rg.find_texture(setup, "final_image")
	depth_tex, ok2 := rg.find_texture(setup, "depth")

	// Find draw buffers from culling
	transparent_cmds, ok3 := rg.find_buffer(setup, "transparent_draw_commands")
	transparent_count, ok4 := rg.find_buffer(setup, "transparent_draw_count")

	if !ok1 || !ok2 || !ok3 || !ok4 {
		// Transparent rendering requires these resources
		return
	}

	// Declare dependencies
	rg.read_buffer(setup, transparent_cmds, .CURRENT)
	rg.read_buffer(setup, transparent_count, .CURRENT)
	rg.read_write_texture(setup, final_image_tex, .CURRENT)
	rg.read_write_texture(setup, depth_tex, .CURRENT)
}

transparent_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	// Begin pass (shared by all techniques)
	color_texture := gpu.get_texture_2d(&manager.texture_manager, cam.attachments[.FINAL_IMAGE][frame_index])
	depth_texture := gpu.get_texture_2d(&manager.texture_manager, cam.attachments[.DEPTH][frame_index])
	gpu.begin_rendering(
		cmd,
		depth_texture.spec.extent,
		gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
		gpu.create_color_attachment(color_texture, .LOAD, .STORE),
	)
	gpu.set_viewport_scissor(cmd, depth_texture.spec.extent)

	// Render transparent objects
	transparent.render(
		&manager.transparent_renderer,
		cmd,
		cam_handle,
		manager.camera_buffer.descriptor_sets[frame_index],
		manager.texture_manager.descriptor_set,
		manager.bone_buffer.descriptor_sets[frame_index],
		manager.material_buffer.descriptor_set,
		manager.node_data_buffer.descriptor_set,
		manager.mesh_data_buffer.descriptor_set,
		manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
		manager.mesh_manager.vertex_buffer.buffer,
		manager.mesh_manager.index_buffer.buffer,
		cam.transparent_draw_commands[frame_index].buffer,
		cam.transparent_draw_count[frame_index].buffer,
		rd.MAX_NODES_IN_SCENE,
	)

	vk.CmdEndRendering(cmd)
}

// ============================================================================
// POST PROCESS PASS (GLOBAL, GRAPHICS)
// ============================================================================

post_process_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Register swapchain as external resource
	swapchain_tex := rg.register_external_texture(
		setup,
		"swapchain",
		rg.TextureDesc{
			width = 1920, height = 1080,
			format = .B8G8R8A8_SRGB,
			usage = {.COLOR_ATTACHMENT},
			aspect = {.COLOR},
			is_external = true,
		},
	)

	// Find final image from main camera (instance 0)
	final_image_tex, ok_final := rg.find_texture_in_scope(setup, "final_image", .PER_CAMERA, 0)
	if !ok_final {
		log.errorf("post_process_setup: Failed to find final_image for camera 0!")
	}

	// Find G-buffer textures for post-process effects
	position_tex, ok_pos := rg.find_texture_in_scope(setup, "gbuffer_position", .PER_CAMERA, 0)
	normal_tex, ok_norm := rg.find_texture_in_scope(setup, "gbuffer_normal", .PER_CAMERA, 0)
	albedo_tex, ok_alb := rg.find_texture_in_scope(setup, "gbuffer_albedo", .PER_CAMERA, 0)
	metallic_roughness_tex, ok_mr := rg.find_texture_in_scope(setup, "gbuffer_metallic_roughness", .PER_CAMERA, 0)
	emissive_tex, ok_em := rg.find_texture_in_scope(setup, "gbuffer_emissive", .PER_CAMERA, 0)
	depth_tex, ok_depth := rg.find_texture_in_scope(setup, "depth", .PER_CAMERA, 0)

	// Dependencies - only declare if resources were found
	if ok_final do rg.read_texture(setup, final_image_tex, .CURRENT)
	if ok_pos do rg.read_texture(setup, position_tex, .CURRENT)
	if ok_norm do rg.read_texture(setup, normal_tex, .CURRENT)
	if ok_alb do rg.read_texture(setup, albedo_tex, .CURRENT)
	if ok_mr do rg.read_texture(setup, metallic_roughness_tex, .CURRENT)
	if ok_em do rg.read_texture(setup, emissive_tex, .CURRENT)
	if ok_depth do rg.read_texture(setup, depth_tex, .CURRENT)
	rg.write_texture(setup, swapchain_tex, .CURRENT)
}

post_process_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data

	// Get main camera (first camera in the map)
	main_cam_index: u32 = 0
	for handle in manager.per_camera_data {
		main_cam_index = handle
		break
	}
	cam, exists := &manager.per_camera_data[main_cam_index]
	if !exists do return

	// Transition final image for shader read
	if final_image := gpu.get_texture_2d(
		&manager.texture_manager,
		cam.attachments[.FINAL_IMAGE][frame_index],
	); final_image != nil {
		gpu.image_barrier(
			cmd,
			final_image.image,
			.COLOR_ATTACHMENT_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.COLOR_ATTACHMENT_WRITE},
			{.SHADER_READ},
			{.COLOR_ATTACHMENT_OUTPUT},
			{.FRAGMENT_SHADER},
			{.COLOR},
		)
	}

	// Transition swapchain image for rendering
	gpu.image_barrier(
		cmd,
		manager.current_swapchain_image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.TOP_OF_PIPE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR},
	)

	// Render post-process
	post_process.begin_pass(&manager.post_process, cmd, manager.current_swapchain_extent)
	post_process.render(
		&manager.post_process,
		cmd,
		manager.current_swapchain_extent,
		manager.current_swapchain_view,
		cam.attachments[.FINAL_IMAGE][frame_index].index,
		cam.attachments[.POSITION][frame_index].index,
		cam.attachments[.NORMAL][frame_index].index,
		cam.attachments[.ALBEDO][frame_index].index,
		cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
		cam.attachments[.EMISSIVE][frame_index].index,
		cam.attachments[.DEPTH][frame_index].index,
		&manager.texture_manager,
	)
	post_process.end_pass(&manager.post_process, cmd)
}

// ============================================================================
// UI PASS (GLOBAL, GRAPHICS)
// ============================================================================

ui_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find swapchain
	swapchain_tex, _ := rg.find_texture(setup, "swapchain")

	// UI writes to swapchain
	rg.read_write_texture(setup, swapchain_tex, .CURRENT)
}

ui_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data

	// UI rendering pass - renders on top of post-processed image
	rendering_attachment_info := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = manager.current_swapchain_view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .LOAD,
		storeOp = .STORE,
	}

	rendering_info := vk.RenderingInfo{
		sType = .RENDERING_INFO,
		renderArea = {extent = manager.current_swapchain_extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &rendering_attachment_info,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)

	// Set viewport and scissor
	viewport := vk.Viewport{
		x = 0,
		y = f32(manager.current_swapchain_extent.height),
		width = f32(manager.current_swapchain_extent.width),
		height = -f32(manager.current_swapchain_extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	scissor := vk.Rect2D{
		offset = {0, 0},
		extent = manager.current_swapchain_extent,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	// Bind pipeline and descriptor sets
	vk.CmdBindPipeline(cmd, .GRAPHICS, manager.ui.pipeline)
	vk.CmdBindDescriptorSets(
		cmd,
		.GRAPHICS,
		manager.ui.pipeline_layout,
		0,
		1,
		&manager.texture_manager.descriptor_set,
		0,
		nil,
	)

	// Render UI using staged commands
	ui_render.render(
		&manager.ui,
		manager.ui_commands[:],
		nil, // gctx not needed here
		&manager.texture_manager,
		cmd,
		manager.current_swapchain_extent.width,
		manager.current_swapchain_extent.height,
		frame_index,
	)

	vk.CmdEndRendering(cmd)
}

// ============================================================================
// DEBUG UI PASS (GLOBAL, GRAPHICS)
// ============================================================================

debug_ui_setup :: proc(setup: ^rg.PassSetup, user_data: rawptr) {
	manager := cast(^Manager)user_data

	// Find swapchain
	swapchain_tex, _ := rg.find_texture(setup, "swapchain")

	// Debug UI writes to swapchain
	rg.read_write_texture(setup, swapchain_tex, .CURRENT)
}

debug_ui_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data

	// Note: Debug UI rendering needs to be controlled by engine
	// For now, we'll always render it if the graph executes
	debug_ui.begin_pass(
		&manager.debug_ui,
		cmd,
		manager.current_swapchain_view,
		manager.current_swapchain_extent,
	)
	debug_ui.render(
		&manager.debug_ui,
		cmd,
		manager.texture_manager.descriptor_set,
	)
	debug_ui.end_pass(&manager.debug_ui, cmd)
}
