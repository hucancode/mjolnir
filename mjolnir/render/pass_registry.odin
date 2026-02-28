package render

import rg "../render/graph"
import vk "vendor:vulkan"

// ============================================================================
// Pass Registry - Central registry for all frame graph passes
// ============================================================================

// Build array of pass declarations for frame graph compilation
build_pass_declarations :: proc(manager: ^Manager) -> [dynamic]rg.PassDecl {
	decls := make([dynamic]rg.PassDecl, 0, 13)

	// Compute passes (run first to prepare data for next frame)
	append(&decls, make_particles_compute_pass_decl(manager))

	// PER_CAMERA compute passes
	append(&decls, make_depth_pyramid_pass_decl(manager))
	append(&decls, make_occlusion_culling_pass_decl(manager))

	// PER_LIGHT compute passes
	append(&decls, make_shadow_culling_pass_decl(manager))

	// PER_LIGHT graphics passes
	append(&decls, make_shadow_render_pass_decl(manager))

	// PER_CAMERA graphics passes
	append(&decls, make_geometry_pass_decl(manager))
	append(&decls, make_ambient_pass_decl(manager))
	append(&decls, make_direct_light_pass_decl(manager))
	append(&decls, make_particles_render_pass_decl(manager))
	append(&decls, make_transparent_pass_decl(manager))

	// GLOBAL graphics passes
	append(&decls, make_post_process_pass_decl(manager))
	append(&decls, make_ui_pass_decl(manager))
	append(&decls, make_debug_ui_pass_decl(manager))

	return decls
}

// ============================================================================
// Pass Declaration Makers
// ============================================================================

// Particles simulation (GLOBAL, COMPUTE)
make_particles_compute_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "particles_compute",
		scope = .GLOBAL,
		queue = .COMPUTE,
		setup = particles_compute_setup,
		execute = particles_compute_execute,
		user_data = manager,
	}
}

// Depth pyramid generation (PER_CAMERA, COMPUTE)
make_depth_pyramid_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "depth_pyramid",
		scope = .PER_CAMERA,
		queue = .COMPUTE,
		setup = depth_pyramid_setup,
		execute = depth_pyramid_execute,
		user_data = manager,
	}
}

// Occlusion culling (PER_CAMERA, COMPUTE)
make_occlusion_culling_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "occlusion_culling",
		scope = .PER_CAMERA,
		queue = .COMPUTE,
		setup = occlusion_culling_setup,
		execute = occlusion_culling_execute,
		user_data = manager,
	}
}

// Shadow culling (PER_LIGHT, COMPUTE)
make_shadow_culling_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "shadow_culling",
		scope = .PER_LIGHT,
		queue = .COMPUTE,
		setup = shadow_culling_setup,
		execute = shadow_culling_execute,
		user_data = manager,
	}
}

// Shadow rendering (PER_LIGHT, GRAPHICS)
make_shadow_render_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "shadow_render",
		scope = .PER_LIGHT,
		queue = .GRAPHICS,
		setup = shadow_render_setup,
		execute = shadow_render_execute,
		user_data = manager,
	}
}

// Geometry pass (PER_CAMERA, GRAPHICS)
make_geometry_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "geometry",
		scope = .PER_CAMERA,
		queue = .GRAPHICS,
		setup = geometry_setup,
		execute = geometry_execute,
		user_data = manager,
	}
}

// Ambient lighting (PER_CAMERA, GRAPHICS)
make_ambient_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "ambient",
		scope = .PER_CAMERA,
		queue = .GRAPHICS,
		setup = ambient_setup,
		execute = ambient_execute,
		user_data = manager,
	}
}

// Direct lighting (PER_CAMERA, GRAPHICS)
make_direct_light_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "direct_light",
		scope = .PER_CAMERA,
		queue = .GRAPHICS,
		setup = direct_light_setup,
		execute = direct_light_execute,
		user_data = manager,
	}
}

// Particles rendering (PER_CAMERA, GRAPHICS)
make_particles_render_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "particles_render",
		scope = .PER_CAMERA,
		queue = .GRAPHICS,
		setup = particles_render_setup,
		execute = particles_render_execute,
		user_data = manager,
	}
}

// Transparent rendering (PER_CAMERA, GRAPHICS)
make_transparent_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "transparent",
		scope = .PER_CAMERA,
		queue = .GRAPHICS,
		setup = transparent_setup,
		execute = transparent_execute,
		user_data = manager,
	}
}

// Post-processing (GLOBAL, GRAPHICS)
make_post_process_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "post_process",
		scope = .GLOBAL,
		queue = .GRAPHICS,
		setup = post_process_setup,
		execute = post_process_execute,
		user_data = manager,
	}
}

// UI rendering (GLOBAL, GRAPHICS)
make_ui_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "ui",
		scope = .GLOBAL,
		queue = .GRAPHICS,
		setup = ui_setup,
		execute = ui_execute,
		user_data = manager,
	}
}

// Debug UI rendering (GLOBAL, GRAPHICS)
make_debug_ui_pass_decl :: proc(manager: ^Manager) -> rg.PassDecl {
	return rg.PassDecl{
		name = "debug_ui",
		scope = .GLOBAL,
		queue = .GRAPHICS,
		setup = debug_ui_setup,
		execute = debug_ui_execute,
		user_data = manager,
	}
}

// ============================================================================
// NOTE: Setup/Execute procedures are implemented in passes_graph.odin
// ============================================================================
