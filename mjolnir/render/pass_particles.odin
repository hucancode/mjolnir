#+private
package render

import "gpu"
import vk "vendor:vulkan"

SHADER_PARTICLE_VERT := #load("shader/particle/vert.spv")
SHADER_PARTICLE_FRAG := #load("shader/particle/frag.spv")

particles_create_render_pipeline :: proc(r: ^Manager) -> (ret: vk.Result) {
	self := &r.internal.particles
	gctx := &r.gctx
	desc := gpu.GraphicsPipelineDesc {
		vert = SHADER_PARTICLE_VERT,
		frag = SHADER_PARTICLE_FRAG,
		topology = .POINT_LIST,
		raster = gpu.DOUBLE_SIDED_RASTERIZER,
		layout = r.internal.scene.layout,
	}
	// drawn in the forward scope
	material_pass_desc(.FORWARD, &desc)
	self.render_pipeline = gpu.create_graphics_pipeline(gctx, desc) or_return
	return .SUCCESS
}

// Draw the live particles listed by the last simulation. Call inside the
// forward render scope.
particles_draw :: proc(r: ^Manager, cmd: vk.CommandBuffer, cam_index: u32) {
	self := &r.internal.particles
	vk.CmdBindPipeline(cmd, .GRAPHICS, self.render_pipeline)
	push := cam_index
	push_constants(r, cmd, &push)
	vk.CmdDrawIndirect(cmd, self.alive_buffer.buffer, 0, 1, size_of(vk.DrawIndirectCommand))
}
