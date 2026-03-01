package render_graph

import "core:fmt"
import "core:strings"
import vk "vendor:vulkan"

// ============================================================================
// Resource Creation API (called during PassSetupProc)
// ============================================================================

// Create a new texture resource
create_texture :: proc(
	setup: ^PassSetup,
	name: string,
	desc: TextureDesc,
) -> TextureId {
	// Scope the name to prevent collisions across instances
	scoped_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)

	// Create resource declaration
	decl := ResourceDecl{
		name = scoped_name,
		type = desc.is_cube ? .TEXTURE_CUBE : .TEXTURE_2D,
		texture_desc = desc,
		scope = setup.pass_scope,
		instance_idx = setup.instance_idx,
	}

	append(&setup.resources, decl)

	// Return typed ID (index is just array position)
	return TextureId{index = u32(len(setup.resources) - 1)}
}

// Create a new buffer resource
create_buffer :: proc(
	setup: ^PassSetup,
	name: string,
	desc: BufferDesc,
) -> BufferId {
	scoped_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)

	decl := ResourceDecl{
		name = scoped_name,
		type = .BUFFER,
		buffer_desc = desc,
		scope = setup.pass_scope,
		instance_idx = setup.instance_idx,
	}

	append(&setup.resources, decl)
	return BufferId{index = u32(len(setup.resources) - 1)}
}

// Register external texture (already allocated, just track dependency)
register_external_texture :: proc(
	setup: ^PassSetup,
	name: string,
	desc: TextureDesc,
) -> TextureId {
	scoped_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)

	// Mark as external
	external_desc := desc
	external_desc.is_external = true

	decl := ResourceDecl{
		name = scoped_name,
		type = external_desc.is_cube ? .TEXTURE_CUBE : .TEXTURE_2D,
		texture_desc = external_desc,
		scope = setup.pass_scope,
		instance_idx = setup.instance_idx,
	}

	append(&setup.resources, decl)
	return TextureId{index = u32(len(setup.resources) - 1)}
}

// Register external buffer
register_external_buffer :: proc(
	setup: ^PassSetup,
	name: string,
	desc: BufferDesc,
) -> BufferId {
	scoped_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)

	external_desc := desc
	external_desc.is_external = true

	decl := ResourceDecl{
		name = scoped_name,
		type = .BUFFER,
		buffer_desc = external_desc,
		scope = setup.pass_scope,
		instance_idx = setup.instance_idx,
	}

	append(&setup.resources, decl)
	return BufferId{index = u32(len(setup.resources) - 1)}
}

// ============================================================================
// Resource Lookup API
// ============================================================================

// Find texture by name (searches current scope first, then global).
// Cross-scope overload: find_texture(setup, name, scope, instance_idx)
@(private)
_find_texture_same_scope :: proc(setup: ^PassSetup, name: string) -> (TextureId, bool) {
	// Try scoped name first (if not global scope)
	if setup.pass_scope != .GLOBAL {
		scoped_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)
		for decl, i in setup.resources {
			if decl.name == scoped_name &&
			   (decl.type == .TEXTURE_2D || decl.type == .TEXTURE_CUBE) {
				return TextureId{index = u32(i)}, true
			}
		}
	}

	// Try unscoped name (global resource)
	for decl, i in setup.resources {
		if decl.name == name &&
		   (decl.type == .TEXTURE_2D || decl.type == .TEXTURE_CUBE) {
			return TextureId{index = u32(i)}, true
		}
	}

	return TextureId{}, false
}

// Cross-scope texture lookup. Example: lighting pass (PER_CAMERA) reading
// shadow maps created by a PER_LIGHT pass at a specific light instance_idx.
@(private)
_find_texture_cross_scope :: proc(
	setup: ^PassSetup,
	name: string,
	scope: PassScope,
	instance_idx: u32,
) -> (TextureId, bool) {
	scoped_name := scope_resource_name(name, scope, instance_idx)
	for decl, i in setup.resources {
		if decl.name == scoped_name &&
		   (decl.type == .TEXTURE_2D || decl.type == .TEXTURE_CUBE) {
			return TextureId{index = u32(i)}, true
		}
	}
	return TextureId{}, false
}

find_texture :: proc{_find_texture_same_scope, _find_texture_cross_scope}

// Find buffer by name (searches current scope first, then global).
// Cross-scope overload: find_buffer(setup, name, scope, instance_idx)
@(private)
_find_buffer_same_scope :: proc(setup: ^PassSetup, name: string) -> (BufferId, bool) {
	// Try scoped name first
	if setup.pass_scope != .GLOBAL {
		scoped_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)
		for decl, i in setup.resources {
			if decl.name == scoped_name && decl.type == .BUFFER {
				return BufferId{index = u32(i)}, true
			}
		}
	}

	// Try unscoped name
	for decl, i in setup.resources {
		if decl.name == name && decl.type == .BUFFER {
			return BufferId{index = u32(i)}, true
		}
	}

	return BufferId{}, false
}

// Cross-scope buffer lookup.
@(private)
_find_buffer_cross_scope :: proc(
	setup: ^PassSetup,
	name: string,
	scope: PassScope,
	instance_idx: u32,
) -> (BufferId, bool) {
	scoped_name := scope_resource_name(name, scope, instance_idx)
	for decl, i in setup.resources {
		if decl.name == scoped_name && decl.type == .BUFFER {
			return BufferId{index = u32(i)}, true
		}
	}
	return BufferId{}, false
}

find_buffer :: proc{_find_buffer_same_scope, _find_buffer_cross_scope}

// ============================================================================
// Dependency Declaration API
// ============================================================================

// Declare read dependency on texture
read_texture :: proc(
	setup: ^PassSetup,
	id: TextureId,
	frame_offset := FrameOffset.CURRENT,
) {
	// Get resource name from declaration
	if int(id.index) >= len(setup.resources) {
		return
	}

	resource_name := setup.resources[id.index].name

	access := ResourceAccess{
		resource_name = resource_name,
		frame_offset = frame_offset,
		access_mode = .READ,
	}

	append(&setup.reads, access)
}

// Declare write dependency on texture
write_texture :: proc(
	setup: ^PassSetup,
	id: TextureId,
	frame_offset := FrameOffset.CURRENT,
) {
	if int(id.index) >= len(setup.resources) {
		return
	}

	resource_name := setup.resources[id.index].name

	access := ResourceAccess{
		resource_name = resource_name,
		frame_offset = frame_offset,
		access_mode = .WRITE,
	}

	append(&setup.writes, access)
}

// Declare read-write dependency on texture
read_write_texture :: proc(
	setup: ^PassSetup,
	id: TextureId,
	frame_offset := FrameOffset.CURRENT,
) {
	if int(id.index) >= len(setup.resources) {
		return
	}

	resource_name := setup.resources[id.index].name

	access := ResourceAccess{
		resource_name = resource_name,
		frame_offset = frame_offset,
		access_mode = .READ_WRITE,
	}

	// Add to both reads and writes
	append(&setup.reads, access)
	append(&setup.writes, access)
}

// Declare read dependency on buffer
read_buffer :: proc(
	setup: ^PassSetup,
	id: BufferId,
	frame_offset := FrameOffset.CURRENT,
) {
	if int(id.index) >= len(setup.resources) {
		return
	}

	resource_name := setup.resources[id.index].name

	access := ResourceAccess{
		resource_name = resource_name,
		frame_offset = frame_offset,
		access_mode = .READ,
	}

	append(&setup.reads, access)
}

// Declare write dependency on buffer
write_buffer :: proc(
	setup: ^PassSetup,
	id: BufferId,
	frame_offset := FrameOffset.CURRENT,
) {
	if int(id.index) >= len(setup.resources) {
		return
	}

	resource_name := setup.resources[id.index].name

	access := ResourceAccess{
		resource_name = resource_name,
		frame_offset = frame_offset,
		access_mode = .WRITE,
	}

	append(&setup.writes, access)
}

// Declare read-write dependency on buffer
read_write_buffer :: proc(
	setup: ^PassSetup,
	id: BufferId,
	frame_offset := FrameOffset.CURRENT,
) {
	if int(id.index) >= len(setup.resources) {
		return
	}

	resource_name := setup.resources[id.index].name

	access := ResourceAccess{
		resource_name = resource_name,
		frame_offset = frame_offset,
		access_mode = .READ_WRITE,
	}

	// Add to both reads and writes
	append(&setup.reads, access)
	append(&setup.writes, access)
}

// ============================================================================
// Batch Dependency Declaration API
// Convenience wrappers for declaring multiple resources at once with the
// default frame offset (.CURRENT). Use the single-item procs above when
// a non-default frame offset (e.g. .NEXT) is required.
// ============================================================================

reads_textures :: proc(setup: ^PassSetup, ids: ..TextureId) {
	for id in ids do read_texture(setup, id)
}

writes_textures :: proc(setup: ^PassSetup, ids: ..TextureId) {
	for id in ids do write_texture(setup, id)
}

reads_buffers :: proc(setup: ^PassSetup, ids: ..BufferId) {
	for id in ids do read_buffer(setup, id)
}

writes_buffers :: proc(setup: ^PassSetup, ids: ..BufferId) {
	for id in ids do write_buffer(setup, id)
}

// ============================================================================
// Helper Functions
// ============================================================================

// Scope resource name to prevent collisions across instances
@(private)
scope_resource_name :: proc(name: string, scope: PassScope, instance_idx: u32) -> string {
	switch scope {
	case .GLOBAL:
		return name
	case .PER_CAMERA:
		return fmt.aprintf("%s_cam_%d", name, instance_idx)
	case .PER_LIGHT:
		return fmt.aprintf("%s_light_%d", name, instance_idx)
	}
	return name
}

// ============================================================================
// Execution-Phase Resource Access API
// ============================================================================

// Get resolved texture from PassResources.
// Tries the exact name first (for global resources and explicit cross-scope
// lookups), then tries the auto-scoped name (for same-scope simple names).
// Example: get_texture(res, "gbuffer_position") in a PER_CAMERA pass
// automatically tries "gbuffer_position_cam_0" if the exact name isn't found.
get_texture :: proc(res: ^PassResources, name: string) -> (ResolvedTexture, bool) {
	if texture, found := res.textures[name]; found {
		return texture, found
	}
	// Auto-scope: try name with this pass's scope suffix
	if res.scope != .GLOBAL {
		scoped: string
		switch res.scope {
		case .PER_CAMERA:
			scoped = fmt.tprintf("%s_cam_%d", name, res.instance_idx)
		case .PER_LIGHT:
			scoped = fmt.tprintf("%s_light_%d", name, res.instance_idx)
		case .GLOBAL:
			unreachable()
		}
		if texture, found := res.textures[scoped]; found {
			return texture, found
		}
	}
	return {}, false
}

// Get resolved buffer from PassResources.
// Same auto-scoping logic as get_texture.
get_buffer :: proc(res: ^PassResources, name: string) -> (ResolvedBuffer, bool) {
	if buffer, found := res.buffers[name]; found {
		return buffer, found
	}
	if res.scope != .GLOBAL {
		scoped: string
		switch res.scope {
		case .PER_CAMERA:
			scoped = fmt.tprintf("%s_cam_%d", name, res.instance_idx)
		case .PER_LIGHT:
			scoped = fmt.tprintf("%s_light_%d", name, res.instance_idx)
		case .GLOBAL:
			unreachable()
		}
		if buffer, found := res.buffers[scoped]; found {
			return buffer, found
		}
	}
	return {}, false
}
