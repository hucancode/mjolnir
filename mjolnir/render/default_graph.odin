package render

// default_graph.odin: builds the default render graph mirroring the current pipeline.
// Used when use_render_graph == true.

import "../gpu"
import "camera"
import rd "data"
import "debug"
import rg "graph"
import "geometry"
import light "lighting"
import oc "occlusion_culling"
import "particles"
import "post_process"
import "transparency"
import vk "vendor:vulkan"

// ============================================================
// Per-pass context structs
// ============================================================

DepthPassCtx :: struct {
	manager:   ^Manager,
	gctx:      ^gpu.GPUContext,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

GeometryPassCtx :: struct {
	manager:   ^Manager,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

LightingPassCtx :: struct {
	manager:       ^Manager,
	cam_index:     u32,
	cam_res:       ^camera.CameraResources,
	active_lights: []rd.LightHandle,
}

ParticlesPassCtx :: struct {
	manager:   ^Manager,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

TransparencyPassCtx :: struct {
	manager:   ^Manager,
	gctx:      ^gpu.GPUContext,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

DebugPassCtx :: struct {
	manager:   ^Manager,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

PostProcessPassCtx :: struct {
	manager:          ^Manager,
	cam_res:          ^camera.CameraResources,
	swapchain_extent: vk.Extent2D,
	swapchain_image:  vk.Image,
	swapchain_view:   vk.ImageView,
}

// ============================================================
// Pass execute callbacks
// ============================================================

@(private)
depth_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^DepthPassCtx)user_data
	m := ctx.manager
	oc.render_depth(
		&m.occlusion_culling,
		ctx.gctx,
		cmd,
		ctx.cam_res,
		&m.texture_manager,
		ctx.cam_index,
		frame_index,
		{.VISIBLE},
		{.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_LINE_STRIP},
		m.camera_buffer.descriptor_sets[frame_index],
		m.bone_buffer.descriptor_sets[frame_index],
		m.node_data_buffer.descriptor_set,
		m.mesh_data_buffer.descriptor_set,
		m.mesh_manager.vertex_skinning_buffer.descriptor_set,
		m.mesh_manager.vertex_buffer.buffer,
		m.mesh_manager.index_buffer.buffer,
	)
}

@(private)
geometry_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^GeometryPassCtx)user_data
	m := ctx.manager
	geometry.begin_pass(ctx.cam_res, &m.texture_manager, cmd, frame_index)
	geometry.render(
		&m.geometry,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		cmd,
		m.camera_buffer.descriptor_sets[frame_index],
		m.texture_manager.descriptor_set,
		m.bone_buffer.descriptor_sets[frame_index],
		m.material_buffer.descriptor_set,
		m.node_data_buffer.descriptor_set,
		m.mesh_data_buffer.descriptor_set,
		m.mesh_manager.vertex_skinning_buffer.descriptor_set,
		m.mesh_manager.vertex_buffer.buffer,
		m.mesh_manager.index_buffer.buffer,
		ctx.cam_res.opaque_draw_commands[frame_index].buffer,
		ctx.cam_res.opaque_draw_count[frame_index].buffer,
	)
	geometry.end_pass(ctx.cam_res, &m.texture_manager, cmd, frame_index)
}

@(private)
lighting_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^LightingPassCtx)user_data
	m := ctx.manager
	light.begin_ambient_pass(
		&m.lighting,
		ctx.cam_res,
		&m.texture_manager,
		cmd,
		m.camera_buffer.descriptor_sets[frame_index],
		frame_index,
	)
	light.render_ambient(&m.lighting, ctx.cam_index, ctx.cam_res, cmd, frame_index)
	light.end_ambient_pass(cmd)

	light.begin_pass(
		&m.lighting,
		ctx.cam_res,
		&m.texture_manager,
		cmd,
		m.camera_buffer.descriptor_sets[frame_index],
		m.lights_buffer.descriptor_set,
		m.shadow.shadow_data_buffer.descriptor_sets[frame_index],
		frame_index,
	)
	shadow_texture_indices: [rd.MAX_LIGHTS]u32
	for i in 0 ..< rd.MAX_LIGHTS {
		shadow_texture_indices[i] = 0xFFFFFFFF
	}
	for handle in ctx.active_lights {
		light_data := gpu.get(&m.lights_buffer.buffer, handle.index)
		shadow_texture_indices[handle.index] = light.shadow_get_texture_index(
			&m.shadow,
			light_data.type,
			light_data.shadow_index,
			frame_index,
		)
	}
	light.render(
		&m.lighting,
		ctx.cam_index,
		ctx.cam_res,
		&shadow_texture_indices,
		cmd,
		&m.lights_buffer,
		ctx.active_lights,
		frame_index,
	)
	light.end_pass(cmd)
}

@(private)
particles_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^ParticlesPassCtx)user_data
	m := ctx.manager
	particles.begin_pass(&m.particles, cmd, ctx.cam_res, &m.texture_manager, frame_index)
	particles.render(
		&m.particles,
		cmd,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		m.camera_buffer.descriptor_sets[frame_index],
		m.texture_manager.descriptor_set,
	)
	particles.end_pass(cmd)
}

@(private)
transparency_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^TransparencyPassCtx)user_data
	m := ctx.manager
	transparency.begin_pass(&m.transparency, ctx.cam_res, &m.texture_manager, cmd, frame_index)
	// Transparent objects
	oc.perform_culling(
		&m.occlusion_culling,
		ctx.gctx,
		cmd,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		NodeFlagSet{.VISIBLE, .MATERIAL_TRANSPARENT},
		NodeFlagSet{.MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_LINE_STRIP, .MATERIAL_SPRITE},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_commands[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_count[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	transparency.render(
		&m.transparency,
		ctx.cam_res,
		m.transparency.transparent_pipeline,
		m.camera_buffer.descriptor_sets[frame_index],
		m.texture_manager.descriptor_set,
		m.bone_buffer.descriptor_sets[frame_index],
		m.material_buffer.descriptor_set,
		m.node_data_buffer.descriptor_set,
		m.mesh_data_buffer.descriptor_set,
		m.sprite_buffer.descriptor_set,
		m.mesh_manager.vertex_skinning_buffer.descriptor_set,
		m.mesh_manager.vertex_buffer.buffer,
		m.mesh_manager.index_buffer.buffer,
		ctx.cam_index,
		frame_index,
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
	)
	// Wireframe
	oc.perform_culling(
		&m.occlusion_culling,
		ctx.gctx,
		cmd,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		NodeFlagSet{.VISIBLE, .MATERIAL_WIREFRAME},
		NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_RANDOM_COLOR, .MATERIAL_LINE_STRIP, .MATERIAL_SPRITE},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_commands[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_count[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	transparency.render(
		&m.transparency,
		ctx.cam_res,
		m.transparency.wireframe_pipeline,
		m.camera_buffer.descriptor_sets[frame_index],
		m.texture_manager.descriptor_set,
		m.bone_buffer.descriptor_sets[frame_index],
		m.material_buffer.descriptor_set,
		m.node_data_buffer.descriptor_set,
		m.mesh_data_buffer.descriptor_set,
		m.sprite_buffer.descriptor_set,
		m.mesh_manager.vertex_skinning_buffer.descriptor_set,
		m.mesh_manager.vertex_buffer.buffer,
		m.mesh_manager.index_buffer.buffer,
		ctx.cam_index,
		frame_index,
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
	)
	// Random color
	oc.perform_culling(
		&m.occlusion_culling,
		ctx.gctx,
		cmd,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		NodeFlagSet{.VISIBLE, .MATERIAL_RANDOM_COLOR},
		NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_LINE_STRIP, .MATERIAL_SPRITE},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_commands[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_count[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	transparency.render(
		&m.transparency,
		ctx.cam_res,
		m.transparency.random_color_pipeline,
		m.camera_buffer.descriptor_sets[frame_index],
		m.texture_manager.descriptor_set,
		m.bone_buffer.descriptor_sets[frame_index],
		m.material_buffer.descriptor_set,
		m.node_data_buffer.descriptor_set,
		m.mesh_data_buffer.descriptor_set,
		m.sprite_buffer.descriptor_set,
		m.mesh_manager.vertex_skinning_buffer.descriptor_set,
		m.mesh_manager.vertex_buffer.buffer,
		m.mesh_manager.index_buffer.buffer,
		ctx.cam_index,
		frame_index,
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
	)
	// Line strip
	oc.perform_culling(
		&m.occlusion_culling,
		ctx.gctx,
		cmd,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		NodeFlagSet{.VISIBLE, .MATERIAL_LINE_STRIP},
		NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_SPRITE},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_commands[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.transparent_draw_count[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	transparency.render(
		&m.transparency,
		ctx.cam_res,
		m.transparency.line_strip_pipeline,
		m.camera_buffer.descriptor_sets[frame_index],
		m.texture_manager.descriptor_set,
		m.bone_buffer.descriptor_sets[frame_index],
		m.material_buffer.descriptor_set,
		m.node_data_buffer.descriptor_set,
		m.mesh_data_buffer.descriptor_set,
		m.sprite_buffer.descriptor_set,
		m.mesh_manager.vertex_skinning_buffer.descriptor_set,
		m.mesh_manager.vertex_buffer.buffer,
		m.mesh_manager.index_buffer.buffer,
		ctx.cam_index,
		frame_index,
		cmd,
		ctx.cam_res.transparent_draw_commands[frame_index].buffer,
		ctx.cam_res.transparent_draw_count[frame_index].buffer,
	)
	// Sprites
	oc.perform_culling(
		&m.occlusion_culling,
		ctx.gctx,
		cmd,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		NodeFlagSet{.VISIBLE, .MATERIAL_SPRITE},
		NodeFlagSet{},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.sprite_draw_commands[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.sprite_draw_commands[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	gpu.buffer_barrier(
		cmd,
		ctx.cam_res.sprite_draw_count[frame_index].buffer,
		vk.DeviceSize(ctx.cam_res.sprite_draw_count[frame_index].bytes_count),
		{.SHADER_WRITE},
		{.INDIRECT_COMMAND_READ},
		{.COMPUTE_SHADER},
		{.DRAW_INDIRECT},
	)
	transparency.render(
		&m.transparency,
		ctx.cam_res,
		m.transparency.sprite_pipeline,
		m.camera_buffer.descriptor_sets[frame_index],
		m.texture_manager.descriptor_set,
		m.bone_buffer.descriptor_sets[frame_index],
		m.material_buffer.descriptor_set,
		m.node_data_buffer.descriptor_set,
		m.mesh_data_buffer.descriptor_set,
		m.sprite_buffer.descriptor_set,
		m.mesh_manager.vertex_skinning_buffer.descriptor_set,
		m.mesh_manager.vertex_buffer.buffer,
		m.mesh_manager.index_buffer.buffer,
		ctx.cam_index,
		frame_index,
		cmd,
		ctx.cam_res.sprite_draw_commands[frame_index].buffer,
		ctx.cam_res.sprite_draw_count[frame_index].buffer,
	)
	transparency.end_pass(&m.transparency, cmd)
}

@(private)
debug_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^DebugPassCtx)user_data
	m := ctx.manager
	if len(m.debug_renderer.bone_instances) == 0 do return
	if !debug.begin_pass(&m.debug_renderer, ctx.cam_res, &m.texture_manager, cmd, frame_index) do return
	debug.render(&m.debug_renderer, cmd, m.camera_buffer.descriptor_sets[frame_index], ctx.cam_index)
	debug.end_pass(&m.debug_renderer, cmd)
}

@(private)
post_process_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^PostProcessPassCtx)user_data
	m := ctx.manager
	// Barriers are handled by the graph
	post_process.begin_pass(&m.post_process, cmd, ctx.swapchain_extent)
	post_process.render(
		&m.post_process,
		cmd,
		ctx.swapchain_extent,
		ctx.swapchain_view,
		ctx.cam_res,
		&m.texture_manager,
		frame_index,
	)
	post_process.end_pass(&m.post_process, cmd)
}

// ============================================================
// Build the default render graph
// ============================================================

// DefaultGraphState holds all the context structs for pass callbacks
DefaultGraphState :: struct {
	depth_ctxs:        [rd.MAX_ACTIVE_CAMERAS]DepthPassCtx,
	geometry_ctxs:     [rd.MAX_ACTIVE_CAMERAS]GeometryPassCtx,
	lighting_ctxs:     [rd.MAX_ACTIVE_CAMERAS]LightingPassCtx,
	particles_ctxs:    [rd.MAX_ACTIVE_CAMERAS]ParticlesPassCtx,
	transparency_ctxs: [rd.MAX_ACTIVE_CAMERAS]TransparencyPassCtx,
	debug_ctxs:        [rd.MAX_ACTIVE_CAMERAS]DebugPassCtx,
	post_process_ctx: PostProcessPassCtx,
}

// build_default_render_graph resets and rebuilds the graph from scratch.
// Must be called after acquiring the swapchain image but before executing.
build_default_render_graph :: proc(
	self: ^Manager,
	gctx: ^gpu.GPUContext,
	active_lights: []rd.LightHandle,
	main_cam_index: u32,
	swapchain_image: vk.Image,
	swapchain_view: vk.ImageView,
	swapchain_extent: vk.Extent2D,
	state: ^DefaultGraphState,
) {
	g := &self.graph
	rg.reset(g)

	// Register swapchain resource with a simple resolve callback
	// We use a persistent pointer for swapchain image/view since they change per frame
	// The resolve callback captures the current swapchain image via user_data
	state.post_process_ctx = PostProcessPassCtx {
		manager          = self,
		cam_res          = &self.camera_resources[main_cam_index],
		swapchain_extent = swapchain_extent,
		swapchain_image  = swapchain_image,
		swapchain_view   = swapchain_view,
	}

	// Register swapchain as a graph resource
	swapchain_res := rg.add_swapchain(
		g,
		"swapchain",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Image, vk.ImageView, vk.Extent2D) {
			ctx := cast(^PostProcessPassCtx)user_data
			return ctx.swapchain_image, ctx.swapchain_view, ctx.swapchain_extent
		},
		&state.post_process_ctx,
	)

	// Shadow pass is handled outside the graph (in engine.odin) until shadow map resources
	// are registered as graph resources in a future phase.

	// Track the main camera's final_image resource to wire into post-process
	main_final_res := rg.ResourceId(rg.INVALID_RESOURCE)

	// Per-camera passes
	cam_idx := u32(0)
	for cam_id, _ in self.cameras {
		cam := &self.cameras[cam_id]
		cam_res := &self.camera_resources[cam_id]

		// Depth prepass
		state.depth_ctxs[cam_idx] = DepthPassCtx {
			manager   = self,
			gctx      = gctx,
			cam_index = cam_id,
			cam_res   = cam_res,
		}
		depth_pass := rg.add_pass(g, "depth_prepass", depth_pass_execute, &state.depth_ctxs[cam_idx])

		// G-buffer geometry pass
		state.geometry_ctxs[cam_idx] = GeometryPassCtx{manager = self, cam_index = cam_id, cam_res = cam_res}
		geom_pass := rg.add_pass(
			g,
			"geometry",
			geometry_pass_execute,
			&state.geometry_ctxs[cam_idx],
		)

		// Register G-buffer resources
		position_res := rg.add_color_texture(
			g,
			"position",
			.R32G32B32A32_SFLOAT,
			proc(
				user_data: rawptr,
				frame_index: u32,
			) -> (
				vk.Image,
				vk.ImageView,
				vk.Extent2D,
			) {
				ctx := cast(^GeometryPassCtx)user_data
				tex := gpu.get_texture_2d(
					&ctx.manager.texture_manager,
					ctx.cam_res.attachments[.POSITION][frame_index],
				)
				if tex == nil do return 0, 0, {}
				return tex.image, tex.view, tex.spec.extent
			},
			&state.geometry_ctxs[cam_idx],
		)
		normal_res := rg.add_color_texture(
			g,
			"normal",
			.R8G8B8A8_UNORM,
			proc(
				user_data: rawptr,
				frame_index: u32,
			) -> (
				vk.Image,
				vk.ImageView,
				vk.Extent2D,
			) {
				ctx := cast(^GeometryPassCtx)user_data
				tex := gpu.get_texture_2d(
					&ctx.manager.texture_manager,
					ctx.cam_res.attachments[.NORMAL][frame_index],
				)
				if tex == nil do return 0, 0, {}
				return tex.image, tex.view, tex.spec.extent
			},
			&state.geometry_ctxs[cam_idx],
		)
		albedo_res := rg.add_color_texture(
			g,
			"albedo",
			.R8G8B8A8_UNORM,
			proc(
				user_data: rawptr,
				frame_index: u32,
			) -> (
				vk.Image,
				vk.ImageView,
				vk.Extent2D,
			) {
				ctx := cast(^GeometryPassCtx)user_data
				tex := gpu.get_texture_2d(
					&ctx.manager.texture_manager,
					ctx.cam_res.attachments[.ALBEDO][frame_index],
				)
				if tex == nil do return 0, 0, {}
				return tex.image, tex.view, tex.spec.extent
			},
			&state.geometry_ctxs[cam_idx],
		)
		metallic_res := rg.add_color_texture(
			g,
			"metallic",
			.R8G8B8A8_UNORM,
			proc(
				user_data: rawptr,
				frame_index: u32,
			) -> (
				vk.Image,
				vk.ImageView,
				vk.Extent2D,
			) {
				ctx := cast(^GeometryPassCtx)user_data
				tex := gpu.get_texture_2d(
					&ctx.manager.texture_manager,
					ctx.cam_res.attachments[.METALLIC_ROUGHNESS][frame_index],
				)
				if tex == nil do return 0, 0, {}
				return tex.image, tex.view, tex.spec.extent
			},
			&state.geometry_ctxs[cam_idx],
		)
		emissive_res := rg.add_color_texture(
			g,
			"emissive",
			.R8G8B8A8_UNORM,
			proc(
				user_data: rawptr,
				frame_index: u32,
			) -> (
				vk.Image,
				vk.ImageView,
				vk.Extent2D,
			) {
				ctx := cast(^GeometryPassCtx)user_data
				tex := gpu.get_texture_2d(
					&ctx.manager.texture_manager,
					ctx.cam_res.attachments[.EMISSIVE][frame_index],
				)
				if tex == nil do return 0, 0, {}
				return tex.image, tex.view, tex.spec.extent
			},
			&state.geometry_ctxs[cam_idx],
		)
		depth_res := rg.add_depth_texture(
			g,
			"depth",
			.D32_SFLOAT,
			proc(
				user_data: rawptr,
				frame_index: u32,
			) -> (
				vk.Image,
				vk.ImageView,
				vk.Extent2D,
			) {
				ctx := cast(^GeometryPassCtx)user_data
				tex := gpu.get_texture_2d(
					&ctx.manager.texture_manager,
					ctx.cam_res.attachments[.DEPTH][frame_index],
				)
				if tex == nil do return 0, 0, {}
				return tex.image, tex.view, tex.spec.extent
			},
			&state.geometry_ctxs[cam_idx],
		)
		final_image_res := rg.add_color_texture(
			g,
			"final_image",
			.B8G8R8A8_SRGB,
			proc(
				user_data: rawptr,
				frame_index: u32,
			) -> (
				vk.Image,
				vk.ImageView,
				vk.Extent2D,
			) {
				ctx := cast(^GeometryPassCtx)user_data
				tex := gpu.get_texture_2d(
					&ctx.manager.texture_manager,
					ctx.cam_res.attachments[.FINAL_IMAGE][frame_index],
				)
				if tex == nil do return 0, 0, {}
				return tex.image, tex.view, tex.spec.extent
			},
			&state.geometry_ctxs[cam_idx],
		)

		// Depth pass: writes depth
		rg.pass_write(g, depth_pass, depth_res, .CLEAR)

		// Geometry pass: reads depth (read-only), writes G-buffer
		rg.pass_read(g, geom_pass, depth_res)
		rg.pass_write(g, geom_pass, position_res, .CLEAR)
		rg.pass_write(g, geom_pass, normal_res, .CLEAR)
		rg.pass_write(g, geom_pass, albedo_res, .CLEAR)
		rg.pass_write(g, geom_pass, metallic_res, .CLEAR)
		rg.pass_write(g, geom_pass, emissive_res, .CLEAR)
		rg.pass_write(g, geom_pass, final_image_res, .CLEAR)

		// Lighting pass
		state.lighting_ctxs[cam_idx] = LightingPassCtx {
			manager       = self,
			cam_index     = cam_id,
			cam_res       = cam_res,
			active_lights = active_lights,
		}
		lighting_pass := rg.add_pass(
			g,
			"lighting",
			lighting_pass_execute,
			&state.lighting_ctxs[cam_idx],
		)
		rg.pass_read(g, lighting_pass, position_res)
		rg.pass_read(g, lighting_pass, normal_res)
		rg.pass_read(g, lighting_pass, albedo_res)
		rg.pass_read(g, lighting_pass, metallic_res)
		rg.pass_read(g, lighting_pass, emissive_res)
		rg.pass_read(g, lighting_pass, depth_res)
		rg.pass_read_write(g, lighting_pass, final_image_res)

		// Particles pass
		if camera.PassType.PARTICLES in cam.enabled_passes {
			state.particles_ctxs[cam_idx] = ParticlesPassCtx {
				manager   = self,
				cam_index = cam_id,
				cam_res   = cam_res,
			}
			particles_pass := rg.add_pass(
				g,
				"particles",
				particles_pass_execute,
				&state.particles_ctxs[cam_idx],
			)
			rg.pass_read_write(g, particles_pass, final_image_res)
			rg.pass_read_write(g, particles_pass, depth_res)
		}

		// Transparency pass
		if camera.PassType.TRANSPARENCY in cam.enabled_passes {
			state.transparency_ctxs[cam_idx] = TransparencyPassCtx {
				manager   = self,
				gctx      = gctx,
				cam_index = cam_id,
				cam_res   = cam_res,
			}
			transparency_pass := rg.add_pass(
				g,
				"transparency",
				transparency_pass_execute,
				&state.transparency_ctxs[cam_idx],
			)
			rg.pass_read_write(g, transparency_pass, final_image_res)
			rg.pass_read_write(g, transparency_pass, depth_res)
		}

		// Debug pass
		state.debug_ctxs[cam_idx] = DebugPassCtx{manager = self, cam_index = cam_id, cam_res = cam_res}
		debug_pass := rg.add_pass(g, "debug", debug_pass_execute, &state.debug_ctxs[cam_idx])
		rg.pass_read_write(g, debug_pass, final_image_res)
		rg.pass_read_write(g, debug_pass, depth_res)

		// Track main camera's final image resource for post-process
		if cam_id == main_cam_index {
			main_final_res = final_image_res
		}

		cam_idx += 1
	}

	// Post-process pass: reads main camera's final_image, writes swapchain
	post_process_pass := rg.add_pass(
		g,
		"post_process",
		post_process_pass_execute,
		&state.post_process_ctx,
	)
	if main_final_res != rg.INVALID_RESOURCE {
		rg.pass_read(g, post_process_pass, main_final_res)
	}
	rg.pass_write(g, post_process_pass, swapchain_res, .CLEAR)

	// Compile the graph
	rg.compile(g)
}
