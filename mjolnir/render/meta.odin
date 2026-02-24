package render

import rg "graph"
import "shadow"
import "core:fmt"

// Template strings use {cam} for PER_CAMERA passes and {slot} for PER_LIGHT passes.

// ====== LIGHT PASSES (PER_LIGHT scope, use {slot}) ======

SHADOW_COMPUTE_PASS :: rg.PassTemplate{
	name = "shadow_compute",
	scope = .PER_LIGHT,
	queue = .COMPUTE,
	inputs = {},
	outputs = {
		"shadow_draw_commands_{slot}",
		"shadow_draw_count_{slot}",
	},
}

SHADOW_DEPTH_PASS :: rg.PassTemplate{
	name = "shadow_depth",
	scope = .PER_LIGHT,
	queue = .GRAPHICS,
	inputs = {
		"shadow_draw_commands_{slot}",
		"shadow_draw_count_{slot}",
	},
	outputs = {
		"shadow_map_{slot}",
	},
}

// ====== CAMERA PASSES (PER_CAMERA scope, use {cam}) ======

DEPTH_PREPASS :: rg.PassTemplate{
	name = "depth_prepass",
	scope = .PER_CAMERA,
	queue = .GRAPHICS,
	inputs = {
		"camera_{cam}_opaque_draw_commands",
		"camera_{cam}_opaque_draw_count",
	},
	outputs = {
		"camera_{cam}_depth",
	},
}

GEOMETRY_PASS :: rg.PassTemplate{
	name = "geometry_pass",
	scope = .PER_CAMERA,
	queue = .GRAPHICS,
	inputs = {
		"camera_{cam}_depth",
		"camera_{cam}_opaque_draw_commands",
		"camera_{cam}_opaque_draw_count",
	},
	outputs = {
		"camera_{cam}_gbuffer_position",
		"camera_{cam}_gbuffer_normal",
		"camera_{cam}_gbuffer_albedo",
		"camera_{cam}_gbuffer_metallic_roughness",
		"camera_{cam}_gbuffer_emissive",
	},
}

AMBIENT_PASS :: rg.PassTemplate{
	name = "ambient_pass",
	scope = .PER_CAMERA,
	queue = .GRAPHICS,
	inputs = {
		"camera_{cam}_gbuffer_position",
		"camera_{cam}_gbuffer_normal",
		"camera_{cam}_gbuffer_albedo",
		"camera_{cam}_gbuffer_metallic_roughness",
		"camera_{cam}_gbuffer_emissive",
	},
	outputs = {
		"camera_{cam}_final_image",
	},
}

DIRECT_LIGHT_PASS :: rg.PassTemplate{
	name = "direct_light_pass",
	scope = .PER_CAMERA,
	queue = .GRAPHICS,
	inputs = {
		"camera_{cam}_gbuffer_position",
		"camera_{cam}_gbuffer_normal",
		"camera_{cam}_gbuffer_albedo",
		"camera_{cam}_gbuffer_metallic_roughness",
		"camera_{cam}_gbuffer_emissive",
		"camera_{cam}_depth",
		// Note: All 16 shadow maps need to be manually listed here
		"shadow_map_0", "shadow_map_1", "shadow_map_2", "shadow_map_3",
		"shadow_map_4", "shadow_map_5", "shadow_map_6", "shadow_map_7",
		"shadow_map_8", "shadow_map_9", "shadow_map_10", "shadow_map_11",
		"shadow_map_12", "shadow_map_13", "shadow_map_14", "shadow_map_15",
		"camera_{cam}_final_image", // Read for blend (loadOp = LOAD)
	},
	outputs = {
		"camera_{cam}_final_image", // Write after blend
	},
}

PARTICLES_RENDER_PASS :: rg.PassTemplate{
	name = "particles_render",
	scope = .PER_CAMERA,
	queue = .GRAPHICS,
	inputs = {
		"compact_particle_buffer",
		"draw_command_buffer",
		"camera_{cam}_depth",
	},
	outputs = {
		"camera_{cam}_final_image",
	},
}

TRANSPARENCY_RENDERING_PASS :: rg.PassTemplate{
	name = "transparency_rendering_pass",
	scope = .PER_CAMERA,
	queue = .GRAPHICS,
	inputs = {
		"camera_{cam}_depth",
		"camera_{cam}_transparent_draw_commands",
		"camera_{cam}_transparent_draw_count",
		"camera_{cam}_wireframe_draw_commands",
		"camera_{cam}_wireframe_draw_count",
		"camera_{cam}_random_color_draw_commands",
		"camera_{cam}_random_color_draw_count",
		"camera_{cam}_line_strip_draw_commands",
		"camera_{cam}_line_strip_draw_count",
		"camera_{cam}_sprite_draw_commands",
		"camera_{cam}_sprite_draw_count",
		"camera_{cam}_final_image", // Read for blend (loadOp = LOAD)
	},
	outputs = {
		"camera_{cam}_final_image", // Write after blend
	},
}

DEBUG_PASS :: rg.PassTemplate{
	name = "debug_pass",
	scope = .PER_CAMERA,
	queue = .GRAPHICS,
	inputs = {
		"camera_{cam}_depth",
		"camera_{cam}_final_image", // Read for blend (loadOp = LOAD)
	},
	outputs = {
		"camera_{cam}_final_image", // Write after blend
	},
}

// ====== GLOBAL PASSES (GLOBAL scope, no templates) ======

POST_PROCESS_PASS :: rg.PassTemplate{
	name = "post_process_pass",
	scope = .GLOBAL,
	queue = .GRAPHICS,
	inputs = {
		// Note: main_camera_index substitution happens in user_data context
		// For now, we don't declare camera_X_final_image dependency here
		// as it requires runtime information
		"post_process_image_0",
		"post_process_image_1", // Conditional on effect_stack length
	},
	outputs = {
		"post_process_image_0",
		"post_process_image_1",
	},
}

UI_PASS :: rg.PassTemplate{
	name = "ui_pass",
	scope = .GLOBAL,
	queue = .GRAPHICS,
	inputs = {
		"ui_vertex_buffer",
		"ui_index_buffer",
		"post_process_image_0", // Dependency for ordering
	},
	outputs = {
		// Swapchain is not a graph resource, so no outputs declared
	},
}
