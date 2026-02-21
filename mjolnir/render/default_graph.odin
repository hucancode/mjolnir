package render

// default_graph.odin: builds the default render graph mirroring the current pipeline.

import "../gpu"
import "camera"
import "core:log"
import rd "data"
import "debug"
import "debug_ui"
import rg "graph"
import "geometry"
import light "lighting"
import oc "occlusion_culling"
import "particles"
import tonemap "post_process/tonemap"
import shd "shadow"
import "transparency"
import ui_render "ui"
import vk "vendor:vulkan"

// Default Graph
// occlusion culling -> geometry -> ambient -> lighting -> tranparent -> sprite -> wireframe -> post process -> swap chain
// shadow compute -> shadow map -> lighting
// ============================================================
// Per-pass context structs
// ============================================================

DepthPassCtx :: struct {
	manager:   ^Manager,
	gctx:      ^gpu.GPUContext,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

ShadowComputePassCtx :: struct {
	manager:        ^Manager,
	render_context: ^RenderContext,
	slot:           u32,
	light_type:     LightType,
	spot:           ^light.SpotLight,
	directional:    ^light.DirectionalLight,
	point:          ^light.PointLight,
}

ShadowSlotCtx :: struct {
	manager:        ^Manager,
	render_context: ^RenderContext,
	slot:           u32,
}

GeometryPassCtx :: struct {
	manager:        ^Manager,
	render_context: ^RenderContext,
	cam_index:      u32,
	cam_res:        ^camera.CameraResources,
}

LightingPassCtx :: struct {
	manager:          ^Manager,
	cam_index:        u32,
	cam_res:          ^camera.CameraResources,
	light_index:      u32,
	shadow_map_index: u32,
}

AmbientPassCtx :: struct {
	manager:   ^Manager,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

ParticleSimulationPassCtx :: struct {
	manager: ^Manager,
}

ParticlesPassCtx :: struct {
	manager:   ^Manager,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

DrawListKind :: enum {
	TRANSPARENT,
	SPRITE,
}

TransparencyCullPassCtx :: struct {
	manager:   ^Manager,
	gctx:      ^gpu.GPUContext,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
	include:   NodeFlagSet,
	exclude:   NodeFlagSet,
	draw_list: DrawListKind,
}

TransparencyRenderPassCtx :: struct {
	manager:        ^Manager,
	render_context: ^RenderContext,
	cam_index:      u32,
	cam_res:        ^camera.CameraResources,
	pipeline:       vk.Pipeline,
	draw_list:      DrawListKind,
}

DebugPassCtx :: struct {
	manager:   ^Manager,
	cam_index: u32,
	cam_res:   ^camera.CameraResources,
}

UIPassCtx :: struct {
	manager:          ^Manager,
	gctx:             ^gpu.GPUContext,
	swapchain_extent: vk.Extent2D,
	swapchain_view:   vk.ImageView,
}

DebugUIPassCtx :: struct {
	manager:          ^Manager,
	enabled:          bool,
	swapchain_extent: vk.Extent2D,
	swapchain_view:   vk.ImageView,
}

// ============================================================
// Swapchain resource resolver
// ============================================================

SwapchainResolveCtx :: struct {
	swapchain_image:  vk.Image,
	swapchain_view:   vk.ImageView,
	swapchain_extent: vk.Extent2D,
}

// ============================================================
// Pass execute callbacks
// ============================================================

@(private)
shadow_compute_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^ShadowComputePassCtx)user_data
	descriptor_set: vk.DescriptorSet
	draw_count_buffer: vk.Buffer
	draw_count_size: vk.DeviceSize
	switch ctx.light_type {
	case .SPOT:
		descriptor_set = ctx.spot.descriptor_sets[frame_index]
		draw_count := &ctx.spot.draw_count[frame_index]
		draw_count_buffer = draw_count.buffer
		draw_count_size = vk.DeviceSize(draw_count.bytes_count)
	case .DIRECTIONAL:
		descriptor_set = ctx.directional.descriptor_sets[frame_index]
		draw_count := &ctx.directional.draw_count[frame_index]
		draw_count_buffer = draw_count.buffer
		draw_count_size = vk.DeviceSize(draw_count.bytes_count)
	case .POINT:
		descriptor_set = ctx.point.descriptor_sets[frame_index]
		draw_count := &ctx.point.draw_count[frame_index]
		draw_count_buffer = draw_count.buffer
		draw_count_size = vk.DeviceSize(draw_count.bytes_count)
	}
	shd.shadow_compute_draw_list(
		&ctx.manager.shadow,
		cmd,
		ctx.slot,
		transmute(rd.LightType)ctx.light_type,
		descriptor_set,
		draw_count_buffer,
		draw_count_size,
	)
}

@(private)
shadow_depth_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^ShadowComputePassCtx)user_data
	m := ctx.manager
	shadow_data_descriptor_set := m.shadow_resources.shadow_data_buffer.descriptor_sets[frame_index]
	draw_commands_buffer: vk.Buffer
	draw_count_buffer: vk.Buffer
	shadow_map_2d: gpu.Texture2DHandle
	shadow_map_cube: gpu.TextureCubeHandle
	switch ctx.light_type {
	case .SPOT:
		draw_commands_buffer = ctx.spot.draw_commands[frame_index].buffer
		draw_count_buffer = ctx.spot.draw_count[frame_index].buffer
		shadow_map_2d = ctx.spot.shadow_map[frame_index]
	case .DIRECTIONAL:
		draw_commands_buffer = ctx.directional.draw_commands[frame_index].buffer
		draw_count_buffer = ctx.directional.draw_count[frame_index].buffer
		shadow_map_2d = ctx.directional.shadow_map[frame_index]
	case .POINT:
		draw_commands_buffer = ctx.point.draw_commands[frame_index].buffer
		draw_count_buffer = ctx.point.draw_count[frame_index].buffer
		shadow_map_cube = ctx.point.shadow_cube[frame_index]
	}
	shd.shadow_render_depth_slot(
		&m.shadow,
		ctx.render_context,
		cmd,
		&m.texture_manager,
		shadow_data_descriptor_set,
		ctx.slot,
		transmute(rd.LightType)ctx.light_type,
		draw_commands_buffer,
		draw_count_buffer,
		shadow_map_2d,
		shadow_map_cube,
	)
}

@(private)
get_transparency_draw_buffers :: proc(
	ctx: ^TransparencyRenderPassCtx,
	frame_index: u32,
) -> (
	draw_buffer: vk.Buffer,
	count_buffer: vk.Buffer,
) {
	switch ctx.draw_list {
	case .TRANSPARENT:
		return ctx.cam_res.transparent_draw_commands[frame_index].buffer, ctx.cam_res.transparent_draw_count[frame_index].buffer
	case .SPRITE:
		return ctx.cam_res.sprite_draw_commands[frame_index].buffer, ctx.cam_res.sprite_draw_count[frame_index].buffer
	}
	return 0, 0
}

@(private)
transparency_cull_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^TransparencyCullPassCtx)user_data
	m := ctx.manager
	oc.perform_culling(
		&m.occlusion_culling,
		ctx.gctx,
		cmd,
		ctx.cam_res,
		ctx.cam_index,
		frame_index,
		ctx.include,
		ctx.exclude,
	)
}

@(private)
transparency_render_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^TransparencyRenderPassCtx)user_data
	m := ctx.manager
	draw_buffer, count_buffer := get_transparency_draw_buffers(ctx, frame_index)
	transparency.begin_pass(&m.transparency, ctx.cam_res, &m.texture_manager, cmd, frame_index)
	transparency.render(
		&m.transparency,
		ctx.render_context,
		cmd,
		ctx.pipeline,
		ctx.cam_index,
		draw_buffer,
		count_buffer,
	)
	transparency.end_pass(&m.transparency, cmd)
}

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
	log.infof("GEOMETRY PASS EXECUTING for camera %v", ctx.cam_index)
	geometry.begin_pass(ctx.cam_res, &m.texture_manager, cmd, frame_index)
	geometry.render(
		&m.geometry,
		ctx.render_context,
		cmd,
		ctx.cam_index,
		ctx.cam_res.opaque_draw_commands[frame_index].buffer,
		ctx.cam_res.opaque_draw_count[frame_index].buffer,
	)
	geometry.end_pass(ctx.cam_res, &m.texture_manager, cmd, frame_index)
}

@(private)
ambient_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^AmbientPassCtx)user_data
	m := ctx.manager
	log.infof("AMBIENT PASS EXECUTING for camera %v", ctx.cam_index)
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
}

@(private)
lighting_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^LightingPassCtx)user_data
	m := ctx.manager
	light.begin_pass(
		&m.lighting,
		ctx.cam_res,
		&m.texture_manager,
		cmd,
		m.camera_buffer.descriptor_sets[frame_index],
		m.lights_buffer.descriptor_set,
		m.shadow_resources.shadow_data_buffer.descriptor_sets[frame_index],
		frame_index,
	)
	light.render_light(
		&m.lighting,
		ctx.cam_index,
		ctx.cam_res,
		ctx.light_index,
		ctx.shadow_map_index,
		cmd,
		&m.lights_buffer,
		frame_index,
	)
	light.end_pass(cmd)
}

@(private)
particle_simulation_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^ParticleSimulationPassCtx)user_data
	m := ctx.manager
	particles.simulate(
		&m.particles,
		cmd,
		m.node_data_buffer.descriptor_set,
		&m.particle_resources.particle_buffer,
		&m.particle_resources.compact_particle_buffer,
	)
}

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
		&m.particle_resources.compact_particle_buffer,
		&m.particle_resources.draw_command_buffer,
	)
	particles.end_pass(cmd)
}

debug_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^DebugPassCtx)user_data
	m := ctx.manager
	if len(m.debug_renderer.bone_instances) == 0 do return
	if !debug.begin_pass(&m.debug_renderer, ctx.cam_res, &m.texture_manager, cmd, frame_index) do return
	debug.render(
		&m.debug_renderer,
		cmd,
		m.camera_buffer.descriptor_sets[frame_index],
		ctx.cam_index,
		&m.debug_resources.bone_instance_buffer,
	)
	debug.end_pass(&m.debug_renderer, cmd)
}


@(private)
ui_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^UIPassCtx)user_data
	m := ctx.manager
	log.infof("UI PASS EXECUTING - swapchain_view=%v", ctx.swapchain_view)

	rendering_attachment_info := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = ctx.swapchain_view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .LOAD,
		storeOp     = .STORE,
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {extent = ctx.swapchain_extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &rendering_attachment_info,
	}
	vk.CmdBeginRendering(cmd, &rendering_info)

	viewport := vk.Viewport {
		x        = 0,
		y        = f32(ctx.swapchain_extent.height),
		width    = f32(ctx.swapchain_extent.width),
		height   = -f32(ctx.swapchain_extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = ctx.swapchain_extent,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	vk.CmdBindPipeline(cmd, .GRAPHICS, m.ui.pipeline)
	vk.CmdBindDescriptorSets(
		cmd,
		.GRAPHICS,
		m.ui.pipeline_layout,
		0,
		1,
		&m.texture_manager.descriptor_set,
		0,
		nil,
	)

	ui_render.render(
		&m.ui,
		m.ui_commands[:],
		ctx.gctx,
		&m.texture_manager,
		cmd,
		ctx.swapchain_extent.width,
		ctx.swapchain_extent.height,
		frame_index,
		&m.ui_resources.vertex_buffers[frame_index],
		&m.ui_resources.index_buffers[frame_index],
	)

	vk.CmdEndRendering(cmd)
}

@(private)
debug_ui_pass_execute :: proc(cmd: vk.CommandBuffer, frame_index: u32, user_data: rawptr) {
	ctx := cast(^DebugUIPassCtx)user_data
	log.infof("DEBUG_UI PASS: enabled=%v", ctx.enabled)
	if !ctx.enabled do return
	m := ctx.manager
	log.infof("DEBUG_UI PASS EXECUTING")
	debug_ui.begin_pass(&m.debug_ui, cmd, ctx.swapchain_view, ctx.swapchain_extent)
	debug_ui.render(
		&m.debug_ui,
		cmd,
		m.texture_manager.descriptor_set,
		&m.debug_ui_resources.vertex_buffer,
		&m.debug_ui_resources.index_buffer,
	)
	debug_ui.end_pass(&m.debug_ui, cmd)
}

// ============================================================
// Build the default render graph
// ============================================================

// DefaultGraphState holds all the context structs for pass callbacks
DefaultGraphState :: struct {
	// Shared render context (built once per frame, used by all passes)
	render_context: RenderContext,
	shadow_compute_ctxs: [shd.MAX_SHADOW_MAPS]ShadowComputePassCtx,
	shadow_compute_count: u32,
	shadow_slot_ctxs:   [shd.MAX_SHADOW_MAPS]ShadowSlotCtx,
	depth_ctxs:        [rd.MAX_ACTIVE_CAMERAS]DepthPassCtx,
	geometry_ctxs:     [rd.MAX_ACTIVE_CAMERAS]GeometryPassCtx,
	ambient_ctxs:      [rd.MAX_ACTIVE_CAMERAS]AmbientPassCtx,
	lighting_ctxs:     [rd.MAX_ACTIVE_CAMERAS * rd.MAX_LIGHTS]LightingPassCtx,
	lighting_count:    u32,
	particle_simulation_ctx: ParticleSimulationPassCtx,
	particles_ctxs:    [rd.MAX_ACTIVE_CAMERAS]ParticlesPassCtx,
	transparency_cull_ctxs:      [rd.MAX_ACTIVE_CAMERAS]TransparencyCullPassCtx,
	transparency_render_ctxs:    [rd.MAX_ACTIVE_CAMERAS]TransparencyRenderPassCtx,
	wireframe_cull_ctxs:         [rd.MAX_ACTIVE_CAMERAS]TransparencyCullPassCtx,
	wireframe_render_ctxs:       [rd.MAX_ACTIVE_CAMERAS]TransparencyRenderPassCtx,
	random_color_cull_ctxs:      [rd.MAX_ACTIVE_CAMERAS]TransparencyCullPassCtx,
	random_color_render_ctxs:    [rd.MAX_ACTIVE_CAMERAS]TransparencyRenderPassCtx,
	sprite_cull_ctxs:            [rd.MAX_ACTIVE_CAMERAS]TransparencyCullPassCtx,
	sprite_render_ctxs:          [rd.MAX_ACTIVE_CAMERAS]TransparencyRenderPassCtx,
	debug_ctxs:        [rd.MAX_ACTIVE_CAMERAS]DebugPassCtx,
	swapchain_ctx:     SwapchainResolveCtx,
	// Default post-process effect context (for simple blit/tonemap to swapchain)
	default_tonemap_ctx: tonemap.PassCtx,
	ui_ctx:            UIPassCtx,
	debug_ui_ctx:      DebugUIPassCtx,
}

// build_default_render_graph resets and rebuilds the graph from scratch.
// Must be called after acquiring the swapchain image but before executing.
//
// Resource Flow (DAG):
// ====================
// Buffers (persistent, registered with resolve callbacks):
//   - particle_buffer: particle_simulation (RW) -> particle_render (R)
//   - debug_bone_instance_buffer: debug_pass (R) [shared across cameras]
//   - ui_vertex_buffer, ui_index_buffer: ui_pass (R) [per-frame]
//   - debug_ui_vertex_buffer, debug_ui_index_buffer: debug_ui_pass (R)
//   - shadow_draw_cmds, shadow_draw_count: shadow_compute (W) -> shadow_depth (R) [per light]
//   - transparent_draw_cmd, transparent_draw_count: transparency_compute (W) -> transparency_render (R) [per camera]
//   - sprite_draw_cmd, sprite_draw_count: sprite_compute (W) -> sprite_render (R) [per camera]
//
// Textures (per-camera, transient or swapchain):
//   - depth: depth_prepass (W) -> geometry (RW) -> lighting (R) -> transparency (RW) -> sprite (RW) -> debug (RW)
//   - albedo, normal, material: geometry (W) -> lighting (R)
//   - final_image: lighting (W) -> particle_render (RW) -> transparency (RW) -> sprite (RW) -> debug (RW) -> tonemap (R)
//   - shadow_map: shadow_depth (W) -> lighting (R) [per light]
//   - swapchain: tonemap (W) -> ui (RW) -> debug_ui (RW) [final output]
//
// Pass Execution Order (topologically sorted by graph compiler):
//   1. particle_simulation (compute)
//   2. shadow_compute (compute, per light)
//   3. shadow_depth (graphics, per light)
//   4. depth_prepass (graphics, per camera)
//   5. geometry (graphics, per camera)
//   6. lighting (graphics, per camera)
//   7. particle_render (graphics, per camera)
//   8. transparency_compute (compute, per camera)
//   9. transparency_render (graphics, per camera)
//   10. sprite_compute (compute, per camera)
//   11. sprite_render (graphics, per camera)
//   12. debug (graphics, per camera)
//   13. tonemap (graphics, main camera only)
//   14. ui (graphics, swapchain)
//   15. debug_ui (graphics, swapchain)
//
build_default_render_graph :: proc(
	self: ^Manager,
	gctx: ^gpu.GPUContext,
	frame_index: u32,
	active_lights: []rd.LightHandle,
	main_cam_index: u32,
	swapchain_image: vk.Image,
	swapchain_view: vk.ImageView,
	swapchain_extent: vk.Extent2D,
	debug_ui_enabled: bool,
	state: ^DefaultGraphState,
) {
	g := &self.graph
	rg.reset(g, gctx, &self.texture_manager)
	state.shadow_compute_count = 0
	state.lighting_count = 0

	// Build shared render context for this frame
	state.render_context = build_render_context(self, frame_index)

	shd.shadow_sync_lights(
		&self.shadow_resources.slot_active,
		&self.shadow_resources.slot_kind,
		&self.shadow_resources.light_to_slot,
		&self.shadow_resources.shadow_data_buffer,
		&self.lights_buffer,
		active_lights,
		frame_index,
	)

	// Register swapchain resource with a simple resolve callback
	state.swapchain_ctx = SwapchainResolveCtx {
		swapchain_image  = swapchain_image,
		swapchain_view   = swapchain_view,
		swapchain_extent = swapchain_extent,
	}

	// Register swapchain as a graph resource
	swapchain_res := rg.add_swapchain(
		g,
		"swapchain",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Image, vk.ImageView, vk.Extent2D) {
			ctx := cast(^SwapchainResolveCtx)user_data
			return ctx.swapchain_image, ctx.swapchain_view, ctx.swapchain_extent
		},
		&state.swapchain_ctx,
	)

	// Register particle buffer resource
	state.particle_simulation_ctx = ParticleSimulationPassCtx{manager = self}

	particle_buffer_res := rg.add_buffer(
		g,
		"particle_buffer",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
			ctx := cast(^ParticleSimulationPassCtx)user_data
			buffer := &ctx.manager.particle_resources.particle_buffer
			return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
		},
		&state.particle_simulation_ctx,
	)

	// Particle simulation compute pass (updates particle positions/velocities)
	particle_simulation_pass := rg.add_pass(
		g,
		"particle_simulation",
		particle_simulation_pass_execute,
		&state.particle_simulation_ctx,
		.COMPUTE,
	)
	rg.pass_read_write(g, particle_simulation_pass, particle_buffer_res)

	shadow_map_resources_by_light: [rd.MAX_LIGHTS]rg.ResourceId
	for i in 0 ..< rd.MAX_LIGHTS {
		shadow_map_resources_by_light[i] = rg.INVALID_RESOURCE
	}

	for handle in active_lights {
		light_data := gpu.get(&self.lights_buffer.buffer, handle.index)
		if !light_data.cast_shadow || light_data.shadow_index == shd.INVALID_SHADOW_INDEX do continue
		if light_data.shadow_index >= shd.MAX_SHADOW_MAPS do continue
		slot := light_data.shadow_index

		// Shadow slot resources are pre-allocated in setup(), just use them
		state.shadow_slot_ctxs[slot] = ShadowSlotCtx {
			manager        = self,
			render_context = &state.render_context,
			slot           = slot,
		}
		ctx_index := state.shadow_compute_count
			state.shadow_compute_ctxs[ctx_index] = ShadowComputePassCtx {
				manager        = self,
				render_context = &state.render_context,
				slot           = slot,
				light_type     = light_data.type,
			}
			switch light_data.type {
			case .SPOT:
				state.shadow_compute_ctxs[ctx_index].spot = &self.shadow_resources.spot_lights[slot]
			case .DIRECTIONAL:
				state.shadow_compute_ctxs[ctx_index].directional = &self.shadow_resources.directional_lights[slot]
			case .POINT:
				state.shadow_compute_ctxs[ctx_index].point = &self.shadow_resources.point_lights[slot]
			}
		state.shadow_compute_count += 1
		ctx := &state.shadow_compute_ctxs[ctx_index]

		shadow_draw_cmd_res := rg.add_buffer(
			g,
			"shadow_draw_cmds",
			proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
				slot_ctx := cast(^ShadowSlotCtx)user_data
				shadow := &slot_ctx.manager.shadow_resources
				slot := slot_ctx.slot
				switch shadow.slot_kind[slot] {
				case .SPOT:
					buffer := &shadow.spot_lights[slot].draw_commands[frame_index]
					return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
				case .DIRECTIONAL:
					buffer := &shadow.directional_lights[slot].draw_commands[frame_index]
					return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
				case .POINT:
					buffer := &shadow.point_lights[slot].draw_commands[frame_index]
					return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
				}
				return 0, 0
			},
			&state.shadow_slot_ctxs[slot],
		)

		shadow_draw_count_res := rg.add_buffer(
			g,
			"shadow_draw_count",
			proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
				slot_ctx := cast(^ShadowSlotCtx)user_data
				shadow := &slot_ctx.manager.shadow_resources
				slot := slot_ctx.slot
				switch shadow.slot_kind[slot] {
				case .SPOT:
					buffer := &shadow.spot_lights[slot].draw_count[frame_index]
					return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
				case .DIRECTIONAL:
					buffer := &shadow.directional_lights[slot].draw_count[frame_index]
					return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
				case .POINT:
					buffer := &shadow.point_lights[slot].draw_count[frame_index]
					return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
				}
				return 0, 0
			},
			&state.shadow_slot_ctxs[slot],
		)

		shadow_map_res := rg.add_depth_texture(
			g,
			"shadow_map",
			.D32_SFLOAT,
			proc(user_data: rawptr, frame_index: u32) -> (vk.Image, vk.ImageView, vk.Extent2D) {
				slot_ctx := cast(^ShadowSlotCtx)user_data
				shadow := &slot_ctx.manager.shadow_resources
				slot := slot_ctx.slot
				switch shadow.slot_kind[slot] {
				case .SPOT:
					tex := gpu.get_texture_2d(
						&slot_ctx.manager.texture_manager,
						shadow.spot_lights[slot].shadow_map[frame_index],
					)
					if tex == nil do return 0, 0, {}
					return tex.image, tex.view, tex.spec.extent
				case .DIRECTIONAL:
					tex := gpu.get_texture_2d(
						&slot_ctx.manager.texture_manager,
						shadow.directional_lights[slot].shadow_map[frame_index],
					)
					if tex == nil do return 0, 0, {}
					return tex.image, tex.view, tex.spec.extent
				case .POINT:
					cube := gpu.get_texture_cube(
						&slot_ctx.manager.texture_manager,
						shadow.point_lights[slot].shadow_cube[frame_index],
					)
					if cube == nil do return 0, 0, {}
					return cube.image, cube.view, vk.Extent2D{shd.SHADOW_MAP_SIZE, shd.SHADOW_MAP_SIZE}
				}
				return 0, 0, {}
			},
			&state.shadow_slot_ctxs[slot],
		)
		shadow_map_resources_by_light[handle.index] = shadow_map_res

		shadow_compute_pass := rg.add_pass(
			g,
			"shadow_compute",
			shadow_compute_pass_execute,
			ctx,
			.COMPUTE,
		)
		rg.pass_write(g, shadow_compute_pass, shadow_draw_cmd_res, .DONT_CARE)
		rg.pass_write(g, shadow_compute_pass, shadow_draw_count_res, .DONT_CARE)

		shadow_depth_pass := rg.add_pass(
			g,
			"shadow_depth",
			shadow_depth_pass_execute,
			ctx,
		)
		rg.pass_read(g, shadow_depth_pass, shadow_draw_cmd_res)
		rg.pass_read(g, shadow_depth_pass, shadow_draw_count_res)
		rg.pass_write(g, shadow_depth_pass, shadow_map_res, .CLEAR)
	}

	// Track the main camera's final_image resource to wire into post-process
	main_final_res := rg.ResourceId(rg.INVALID_RESOURCE)

	// Register debug bone instance buffer (shared across all cameras)
	// Note: We use a simple context with just manager for the resolve callback
	debug_bone_buffer_ctx := struct { manager: ^Manager }{manager = self}
	debug_bone_buffer_res := rg.add_buffer(
		g,
		"debug_bone_instance_buffer",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
			ctx := cast(^struct { manager: ^Manager })user_data
			buffer := &ctx.manager.debug_resources.bone_instance_buffer
			return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
		},
		&debug_bone_buffer_ctx,
	)

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
		depth_pass := rg.add_pass(g, "occlusion_culling", depth_pass_execute, &state.depth_ctxs[cam_idx])

		// G-buffer geometry pass
		state.geometry_ctxs[cam_idx] = GeometryPassCtx {
			manager        = self,
			render_context = &state.render_context,
			cam_index      = cam_id,
			cam_res        = cam_res,
		}
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
		transparent_draw_cmd_res := rg.add_buffer(
			g,
			"transparent_draw_cmds",
			proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
				ctx := cast(^GeometryPassCtx)user_data
				buffer := &ctx.cam_res.transparent_draw_commands[frame_index]
				return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
			},
			&state.geometry_ctxs[cam_idx],
		)
		transparent_draw_count_res := rg.add_buffer(
			g,
			"transparent_draw_count",
			proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
				ctx := cast(^GeometryPassCtx)user_data
				buffer := &ctx.cam_res.transparent_draw_count[frame_index]
				return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
			},
			&state.geometry_ctxs[cam_idx],
		)
		sprite_draw_cmd_res := rg.add_buffer(
			g,
			"sprite_draw_cmds",
			proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
				ctx := cast(^GeometryPassCtx)user_data
				buffer := &ctx.cam_res.sprite_draw_commands[frame_index]
				return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
			},
			&state.geometry_ctxs[cam_idx],
		)
		sprite_draw_count_res := rg.add_buffer(
			g,
			"sprite_draw_count",
			proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
				ctx := cast(^GeometryPassCtx)user_data
				buffer := &ctx.cam_res.sprite_draw_count[frame_index]
				return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
			},
			&state.geometry_ctxs[cam_idx],
		)
		transparency_seq_res := rg.add_buffer(
			g,
			"transparency_sequence_token",
			proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
				ctx := cast(^GeometryPassCtx)user_data
				buffer := &ctx.manager.camera_buffer.buffers[frame_index]
				return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
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

		state.ambient_ctxs[cam_idx] = AmbientPassCtx {
			manager   = self,
			cam_index = cam_id,
			cam_res   = cam_res,
		}
		ambient_pass := rg.add_pass(
			g,
			"ambient",
			ambient_pass_execute,
			&state.ambient_ctxs[cam_idx],
		)
		rg.pass_read(g, ambient_pass, position_res)
		rg.pass_read(g, ambient_pass, normal_res)
		rg.pass_read(g, ambient_pass, albedo_res)
		rg.pass_read(g, ambient_pass, metallic_res)
		rg.pass_read(g, ambient_pass, emissive_res)
		rg.pass_write(g, ambient_pass, final_image_res, .CLEAR)

		for handle in active_lights {
			if state.lighting_count >= len(state.lighting_ctxs) do break
			light_data := gpu.get(&self.lights_buffer.buffer, handle.index)
			lighting_ctx_idx := state.lighting_count
			state.lighting_count += 1
			state.lighting_ctxs[lighting_ctx_idx] = LightingPassCtx {
				manager          = self,
				cam_index        = cam_id,
				cam_res          = cam_res,
				light_index      = handle.index,
				shadow_map_index = shd.INVALID_SHADOW_INDEX,
			}
			if light_data.cast_shadow && light_data.shadow_index < shd.MAX_SHADOW_MAPS {
				slot := light_data.shadow_index
				spot_shadow_map: gpu.Texture2DHandle
				directional_shadow_map: gpu.Texture2DHandle
				point_shadow_cube: gpu.TextureCubeHandle
				switch light_data.type {
				case .SPOT:
					spot_shadow_map = self.shadow_resources.spot_lights[slot].shadow_map[frame_index]
				case .DIRECTIONAL:
					directional_shadow_map = self.shadow_resources.directional_lights[slot].shadow_map[frame_index]
				case .POINT:
					point_shadow_cube = self.shadow_resources.point_lights[slot].shadow_cube[frame_index]
				}
				state.lighting_ctxs[lighting_ctx_idx].shadow_map_index = shd.shadow_get_texture_index(
					light_data.type,
					spot_shadow_map,
					directional_shadow_map,
					point_shadow_cube,
				)
			}

			lighting_pass := rg.add_pass(
				g,
				"lighting",
				lighting_pass_execute,
				&state.lighting_ctxs[lighting_ctx_idx],
			)
			rg.pass_read(g, lighting_pass, position_res)
			rg.pass_read(g, lighting_pass, normal_res)
			rg.pass_read(g, lighting_pass, albedo_res)
			rg.pass_read(g, lighting_pass, metallic_res)
			rg.pass_read(g, lighting_pass, emissive_res)
			rg.pass_read(g, lighting_pass, depth_res)
			rg.pass_read_write(g, lighting_pass, final_image_res)
			if shadow_map_res := shadow_map_resources_by_light[handle.index]; shadow_map_res != rg.INVALID_RESOURCE {
				rg.pass_read(g, lighting_pass, shadow_map_res)
			}
		}

		// Particle render pass
		if camera.PassType.PARTICLES in cam.enabled_passes {
			state.particles_ctxs[cam_idx] = ParticlesPassCtx {
				manager   = self,
				cam_index = cam_id,
				cam_res   = cam_res,
			}
			particle_render_pass := rg.add_pass(
				g,
				"particle_render",
				particles_pass_execute,
				&state.particles_ctxs[cam_idx],
			)
			rg.pass_read(g, particle_render_pass, particle_buffer_res)
			rg.pass_read_write(g, particle_render_pass, final_image_res)
			rg.pass_read_write(g, particle_render_pass, depth_res)
		}

		// Transparency passes (decomposed)
		if camera.PassType.TRANSPARENCY in cam.enabled_passes {
			state.transparency_cull_ctxs[cam_idx] = TransparencyCullPassCtx {
				manager   = self,
				gctx      = gctx,
				cam_index = cam_id,
				cam_res   = cam_res,
				include   = NodeFlagSet{.VISIBLE, .MATERIAL_TRANSPARENT},
				exclude   = NodeFlagSet{.MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_LINE_STRIP, .MATERIAL_SPRITE},
				draw_list = .TRANSPARENT,
			}
			transparency_cull_pass := rg.add_pass(
				g,
				"transparency_cull",
				transparency_cull_pass_execute,
				&state.transparency_cull_ctxs[cam_idx],
			)
			rg.pass_read(g, transparency_cull_pass, final_image_res)
			rg.pass_read(g, transparency_cull_pass, depth_res)
			rg.pass_write(g, transparency_cull_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_write(g, transparency_cull_pass, transparent_draw_cmd_res, .DONT_CARE)
			rg.pass_write(g, transparency_cull_pass, transparent_draw_count_res, .DONT_CARE)
			state.transparency_render_ctxs[cam_idx] = TransparencyRenderPassCtx {
				manager        = self,
				render_context = &state.render_context,
				cam_index      = cam_id,
				cam_res        = cam_res,
				pipeline       = self.transparency.transparent_pipeline,
				draw_list      = .TRANSPARENT,
			}
			transparency_render_pass := rg.add_pass(
				g,
				"transparency",
				transparency_render_pass_execute,
				&state.transparency_render_ctxs[cam_idx],
			)
			rg.pass_read(g, transparency_render_pass, transparency_seq_res)
			rg.pass_write(g, transparency_render_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_read(g, transparency_render_pass, transparent_draw_cmd_res)
			rg.pass_read(g, transparency_render_pass, transparent_draw_count_res)
			rg.pass_read_write(g, transparency_render_pass, final_image_res)
			rg.pass_read_write(g, transparency_render_pass, depth_res)

			state.wireframe_cull_ctxs[cam_idx] = TransparencyCullPassCtx {
				manager   = self,
				gctx      = gctx,
				cam_index = cam_id,
				cam_res   = cam_res,
				include   = NodeFlagSet{.VISIBLE, .MATERIAL_WIREFRAME},
				exclude   = NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_RANDOM_COLOR, .MATERIAL_LINE_STRIP, .MATERIAL_SPRITE},
				draw_list = .TRANSPARENT,
			}
			wireframe_cull_pass := rg.add_pass(
				g,
				"wireframe_cull",
				transparency_cull_pass_execute,
				&state.wireframe_cull_ctxs[cam_idx],
			)
			rg.pass_read(g, wireframe_cull_pass, final_image_res)
			rg.pass_read(g, wireframe_cull_pass, depth_res)
			rg.pass_read(g, wireframe_cull_pass, transparency_seq_res)
			rg.pass_write(g, wireframe_cull_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_write(g, wireframe_cull_pass, transparent_draw_cmd_res, .DONT_CARE)
			rg.pass_write(g, wireframe_cull_pass, transparent_draw_count_res, .DONT_CARE)
			state.wireframe_render_ctxs[cam_idx] = TransparencyRenderPassCtx {
				manager        = self,
				render_context = &state.render_context,
				cam_index      = cam_id,
				cam_res        = cam_res,
				pipeline       = self.transparency.wireframe_pipeline,
				draw_list      = .TRANSPARENT,
			}
			wireframe_render_pass := rg.add_pass(
				g,
				"wireframe",
				transparency_render_pass_execute,
				&state.wireframe_render_ctxs[cam_idx],
			)
			rg.pass_read(g, wireframe_render_pass, transparency_seq_res)
			rg.pass_write(g, wireframe_render_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_read(g, wireframe_render_pass, transparent_draw_cmd_res)
			rg.pass_read(g, wireframe_render_pass, transparent_draw_count_res)
			rg.pass_read_write(g, wireframe_render_pass, final_image_res)
			rg.pass_read_write(g, wireframe_render_pass, depth_res)

			state.random_color_cull_ctxs[cam_idx] = TransparencyCullPassCtx {
				manager   = self,
				gctx      = gctx,
				cam_index = cam_id,
				cam_res   = cam_res,
				include   = NodeFlagSet{.VISIBLE, .MATERIAL_RANDOM_COLOR},
				exclude   = NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_LINE_STRIP, .MATERIAL_SPRITE},
				draw_list = .TRANSPARENT,
			}
			random_color_cull_pass := rg.add_pass(
				g,
				"random_color_cull",
				transparency_cull_pass_execute,
				&state.random_color_cull_ctxs[cam_idx],
			)
			rg.pass_read(g, random_color_cull_pass, final_image_res)
			rg.pass_read(g, random_color_cull_pass, depth_res)
			rg.pass_read(g, random_color_cull_pass, transparency_seq_res)
			rg.pass_write(g, random_color_cull_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_write(g, random_color_cull_pass, transparent_draw_cmd_res, .DONT_CARE)
			rg.pass_write(g, random_color_cull_pass, transparent_draw_count_res, .DONT_CARE)
			state.random_color_render_ctxs[cam_idx] = TransparencyRenderPassCtx {
				manager        = self,
				render_context = &state.render_context,
				cam_index      = cam_id,
				cam_res        = cam_res,
				pipeline       = self.transparency.random_color_pipeline,
				draw_list      = .TRANSPARENT,
			}
			random_color_render_pass := rg.add_pass(
				g,
				"random_color",
				transparency_render_pass_execute,
				&state.random_color_render_ctxs[cam_idx],
			)
			rg.pass_read(g, random_color_render_pass, transparency_seq_res)
			rg.pass_write(g, random_color_render_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_read(g, random_color_render_pass, transparent_draw_cmd_res)
			rg.pass_read(g, random_color_render_pass, transparent_draw_count_res)
			rg.pass_read_write(g, random_color_render_pass, final_image_res)
			rg.pass_read_write(g, random_color_render_pass, depth_res)

			state.sprite_cull_ctxs[cam_idx] = TransparencyCullPassCtx {
				manager   = self,
				gctx      = gctx,
				cam_index = cam_id,
				cam_res   = cam_res,
				include   = NodeFlagSet{.VISIBLE, .MATERIAL_SPRITE},
				exclude   = NodeFlagSet{},
				draw_list = .SPRITE,
			}
			sprite_cull_pass := rg.add_pass(
				g,
				"sprite_cull",
				transparency_cull_pass_execute,
				&state.sprite_cull_ctxs[cam_idx],
			)
			rg.pass_read(g, sprite_cull_pass, final_image_res)
			rg.pass_read(g, sprite_cull_pass, depth_res)
			rg.pass_read(g, sprite_cull_pass, transparency_seq_res)
			rg.pass_write(g, sprite_cull_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_write(g, sprite_cull_pass, sprite_draw_cmd_res, .DONT_CARE)
			rg.pass_write(g, sprite_cull_pass, sprite_draw_count_res, .DONT_CARE)
			state.sprite_render_ctxs[cam_idx] = TransparencyRenderPassCtx {
				manager        = self,
				render_context = &state.render_context,
				cam_index      = cam_id,
				cam_res        = cam_res,
				pipeline       = self.transparency.sprite_pipeline,
				draw_list      = .SPRITE,
			}
			sprite_render_pass := rg.add_pass(
				g,
				"sprite",
				transparency_render_pass_execute,
				&state.sprite_render_ctxs[cam_idx],
			)
			rg.pass_read(g, sprite_render_pass, transparency_seq_res)
			rg.pass_write(g, sprite_render_pass, transparency_seq_res, .DONT_CARE)
			rg.pass_read(g, sprite_render_pass, sprite_draw_cmd_res)
			rg.pass_read(g, sprite_render_pass, sprite_draw_count_res)
			rg.pass_read_write(g, sprite_render_pass, final_image_res)
			rg.pass_read_write(g, sprite_render_pass, depth_res)
		}

		// Debug pass
		state.debug_ctxs[cam_idx] = DebugPassCtx{manager = self, cam_index = cam_id, cam_res = cam_res}
		debug_pass := rg.add_pass(g, "debug", debug_pass_execute, &state.debug_ctxs[cam_idx])
		rg.pass_read(g, debug_pass, debug_bone_buffer_res)
		rg.pass_read_write(g, debug_pass, final_image_res)
		rg.pass_read_write(g, debug_pass, depth_res)

		// Track main camera's final image resource for post-process
		if cam_id == main_cam_index {
			main_final_res = final_image_res
			log.infof("Found main camera (id=%v), setting main_final_res=%v", cam_id, main_final_res)
		}

		cam_idx += 1
	}

	// Default post-processing: simple tonemap to swapchain
	// Users can customize this by adding their own node chains before the final blit
	if main_final_res != rg.INVALID_RESOURCE {
		main_cam_res := &self.camera_resources[main_cam_index]
		log.infof("Adding default tonemap node: input_res=%v, swapchain_res=%v", main_final_res, swapchain_res)
		output_res := tonemap.add_node(
			g,
			&self.tonemap_renderer,
			&self.texture_manager,
			main_cam_res,
			main_final_res,
			swapchain_extent,
			frame_index,
			tonemap.Config{exposure = 1.0, gamma = 2.2},
			true, // is_final_output
			swapchain_res,
			swapchain_view,
			&state.default_tonemap_ctx,
		)
		log.infof("Tonemap node output_res=%v", output_res)
	} else {
		log.warn("main_final_res is INVALID, skipping post-processing")
	}

	// UI pass: overlays UI on top of swapchain
	state.ui_ctx = UIPassCtx {
		manager          = self,
		gctx             = gctx,
		swapchain_extent = swapchain_extent,
		swapchain_view   = swapchain_view,
	}

	// Register UI buffers with graph (for documentation and dependency tracking)
	ui_vertex_buffer_res := rg.add_buffer(
		g,
		"ui_vertex_buffer",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
			ctx := cast(^UIPassCtx)user_data
			buffer := &ctx.manager.ui_resources.vertex_buffers[frame_index]
			return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
		},
		&state.ui_ctx,
	)
	ui_index_buffer_res := rg.add_buffer(
		g,
		"ui_index_buffer",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
			ctx := cast(^UIPassCtx)user_data
			buffer := &ctx.manager.ui_resources.index_buffers[frame_index]
			return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
		},
		&state.ui_ctx,
	)
	ui_pass := rg.add_pass(g, "ui", ui_pass_execute, &state.ui_ctx)
	rg.pass_read(g, ui_pass, ui_vertex_buffer_res)
	rg.pass_read(g, ui_pass, ui_index_buffer_res)
	rg.pass_read_write(g, ui_pass, swapchain_res)

	// Debug UI pass: overlays debug UI after UI
	state.debug_ui_ctx = DebugUIPassCtx {
		manager          = self,
		enabled          = debug_ui_enabled,
		swapchain_extent = swapchain_extent,
		swapchain_view   = swapchain_view,
	}

	// Register Debug UI buffers with graph
	debug_ui_vertex_buffer_res := rg.add_buffer(
		g,
		"debug_ui_vertex_buffer",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
			ctx := cast(^DebugUIPassCtx)user_data
			buffer := &ctx.manager.debug_ui_resources.vertex_buffer
			return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
		},
		&state.debug_ui_ctx,
	)
	debug_ui_index_buffer_res := rg.add_buffer(
		g,
		"debug_ui_index_buffer",
		proc(user_data: rawptr, frame_index: u32) -> (vk.Buffer, vk.DeviceSize) {
			ctx := cast(^DebugUIPassCtx)user_data
			buffer := &ctx.manager.debug_ui_resources.index_buffer
			return buffer.buffer, vk.DeviceSize(buffer.bytes_count)
		},
		&state.debug_ui_ctx,
	)

	debug_ui_pass := rg.add_pass(g, "debug_ui", debug_ui_pass_execute, &state.debug_ui_ctx)
	rg.pass_read(g, debug_ui_pass, debug_ui_vertex_buffer_res)
	rg.pass_read(g, debug_ui_pass, debug_ui_index_buffer_res)
	rg.pass_read_write(g, debug_ui_pass, swapchain_res)

	// Compile the graph
	rg.compile(g)
}
