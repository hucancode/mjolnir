package render_graph

import "core:fmt"
import vk "vendor:vulkan"

// ============================================================================
// Resource Creation API (called during PassSetupProc)
// ============================================================================

create_texture :: proc(setup: ^PassSetup, name: string, desc: TextureDesc) -> TextureId {
	return _add_texture(setup, name, desc)
}

create_buffer :: proc(setup: ^PassSetup, name: string, desc: BufferDesc) -> BufferId {
	return _add_buffer(setup, name, desc)
}

register_external_texture :: proc(setup: ^PassSetup, name: string, desc: TextureDesc) -> TextureId {
	d := desc
	d.is_external = true
	return _add_texture(setup, name, d)
}

register_external_buffer :: proc(setup: ^PassSetup, name: string, desc: BufferDesc) -> BufferId {
	d := desc
	d.is_external = true
	return _add_buffer(setup, name, d)
}

@(private)
_add_texture :: proc(setup: ^PassSetup, name: string, desc: TextureDesc) -> TextureId {
	resolved_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)
	tex_type := ResourceType.TEXTURE_CUBE if desc.is_cube else .TEXTURE_2D
	// Deduplicate: if this scoped name already exists (registered by an earlier pass),
	// return that entry's index so all accesses share the same canonical string.
	for decl, i in setup._resources {
		if decl.name == resolved_name && (decl.type == .TEXTURE_2D || decl.type == .TEXTURE_CUBE) {
			if setup.pass_scope != .GLOBAL do delete(resolved_name)
			return TextureId{index = u32(i)}
		}
	}
	decl := ResourceDecl{
		name         = resolved_name,
		type         = tex_type,
		texture_desc = desc,
		scope        = setup.pass_scope,
		instance_idx = setup.instance_idx,
	}
	append(&setup._resources, decl)
	return TextureId{index = u32(len(setup._resources) - 1)}
}

@(private)
_add_buffer :: proc(setup: ^PassSetup, name: string, desc: BufferDesc) -> BufferId {
	resolved_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)
	// Deduplicate: if this scoped name already exists (registered by an earlier pass),
	// return that entry's index so all accesses share the same canonical string.
	for decl, i in setup._resources {
		if decl.name == resolved_name && decl.type == .BUFFER {
			if setup.pass_scope != .GLOBAL do delete(resolved_name)
			return BufferId{index = u32(i)}
		}
	}
	decl := ResourceDecl{
		name         = resolved_name,
		type         = .BUFFER,
		buffer_desc  = desc,
		scope        = setup.pass_scope,
		instance_idx = setup.instance_idx,
	}
	append(&setup._resources, decl)
	return BufferId{index = u32(len(setup._resources) - 1)}
}

// ============================================================================
// Resource Lookup API
// ============================================================================

// Find texture by name (searches current scope first, then global).
// Cross-scope overload: find_texture(setup, name, scope, instance_idx)
@(private)
_find_texture_same_scope :: proc(setup: ^PassSetup, name: string) -> (TextureId, bool) {
	if setup.pass_scope != .GLOBAL {
		scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(setup.pass_scope), setup.instance_idx)
		for decl, i in setup._resources {
			if decl.name == scoped && (decl.type == .TEXTURE_2D || decl.type == .TEXTURE_CUBE) {
				return TextureId{index = u32(i)}, true
			}
		}
	}
	for decl, i in setup._resources {
		if decl.name == name && (decl.type == .TEXTURE_2D || decl.type == .TEXTURE_CUBE) {
			return TextureId{index = u32(i)}, true
		}
	}
	return TextureId{}, false
}

@(private)
_find_texture_cross_scope :: proc(
	setup: ^PassSetup,
	name: string,
	scope: PassScope,
	instance_idx: u32,
) -> (TextureId, bool) {
	scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(scope), instance_idx)
	for decl, i in setup._resources {
		if decl.name == scoped && (decl.type == .TEXTURE_2D || decl.type == .TEXTURE_CUBE) {
			return TextureId{index = u32(i)}, true
		}
	}
	return TextureId{}, false
}

find_texture :: proc{_find_texture_same_scope, _find_texture_cross_scope}

@(private)
_find_buffer_same_scope :: proc(setup: ^PassSetup, name: string) -> (BufferId, bool) {
	if setup.pass_scope != .GLOBAL {
		scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(setup.pass_scope), setup.instance_idx)
		for decl, i in setup._resources {
			if decl.name == scoped && decl.type == .BUFFER {
				return BufferId{index = u32(i)}, true
			}
		}
	}
	for decl, i in setup._resources {
		if decl.name == name && decl.type == .BUFFER {
			return BufferId{index = u32(i)}, true
		}
	}
	return BufferId{}, false
}

@(private)
_find_buffer_cross_scope :: proc(
	setup: ^PassSetup,
	name: string,
	scope: PassScope,
	instance_idx: u32,
) -> (BufferId, bool) {
	scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(scope), instance_idx)
	for decl, i in setup._resources {
		if decl.name == scoped && decl.type == .BUFFER {
			return BufferId{index = u32(i)}, true
		}
	}
	return BufferId{}, false
}

find_buffer :: proc{_find_buffer_same_scope, _find_buffer_cross_scope}

// ============================================================================
// Dependency Declaration API
// ============================================================================

read_texture  :: proc(setup: ^PassSetup, id: TextureId, frame_offset := FrameOffset.CURRENT) { _declare_access(setup, id.index, .READ,       frame_offset) }
write_texture :: proc(setup: ^PassSetup, id: TextureId, frame_offset := FrameOffset.CURRENT) { _declare_access(setup, id.index, .WRITE,      frame_offset) }
read_buffer   :: proc(setup: ^PassSetup, id: BufferId,  frame_offset := FrameOffset.CURRENT) { _declare_access(setup, id.index, .READ,       frame_offset) }
write_buffer  :: proc(setup: ^PassSetup, id: BufferId,  frame_offset := FrameOffset.CURRENT) { _declare_access(setup, id.index, .WRITE,      frame_offset) }
read_write_texture :: proc(setup: ^PassSetup, id: TextureId, frame_offset := FrameOffset.CURRENT) { _declare_access(setup, id.index, .READ_WRITE, frame_offset) }
read_write_buffer  :: proc(setup: ^PassSetup, id: BufferId,  frame_offset := FrameOffset.CURRENT) { _declare_access(setup, id.index, .READ_WRITE, frame_offset) }

@(private)
_declare_access :: proc(setup: ^PassSetup, index: u32, access: AccessMode, frame_offset: FrameOffset) {
	if int(index) >= len(setup._resources) do return
	name := setup._resources[index].name
	acc  := ResourceAccess{resource_name = name, frame_offset = frame_offset, access_mode = access}
	if access != .WRITE do append(&setup._reads,  acc)
	if access != .READ  do append(&setup._writes, acc)
}

// ============================================================================
// Batch Dependency Declaration API
// ============================================================================

reads_textures  :: proc(setup: ^PassSetup, ids: ..TextureId) { for id in ids do read_texture(setup, id) }
writes_textures :: proc(setup: ^PassSetup, ids: ..TextureId) { for id in ids do write_texture(setup, id) }
reads_buffers   :: proc(setup: ^PassSetup, ids: ..BufferId)  { for id in ids do read_buffer(setup, id) }
writes_buffers  :: proc(setup: ^PassSetup, ids: ..BufferId)  { for id in ids do write_buffer(setup, id) }

// ============================================================================
// Helper Functions
// ============================================================================

// Returns the scope suffix string for a given scope (used for name scoping).
@(private)
_scope_suffix :: proc(scope: PassScope) -> string {
	switch scope {
	case .PER_CAMERA: return "cam"
	case .PER_LIGHT:  return "light"
	case .GLOBAL:     return ""
	}
	return ""
}

// Returns a heap-allocated scoped resource name (fmt.aprintf).
// Caller is responsible for freeing if scope != .GLOBAL.
// Used by creation procs for persistent storage in ResourceDecl/ResourceInstance.
@(private)
scope_resource_name :: proc(name: string, scope: PassScope, instance_idx: u32) -> string {
	switch scope {
	case .GLOBAL:     return name
	case .PER_CAMERA: return fmt.aprintf("%s_cam_%d", name, instance_idx)
	case .PER_LIGHT:  return fmt.aprintf("%s_light_%d", name, instance_idx)
	}
	return name
}

// ============================================================================
// Execution-Phase Resource Access API
// ============================================================================

// Get resolved texture from PassResources.
// Tries exact name first (cross-scope/global), then auto-scopes to this pass's instance.
get_texture :: proc(res: ^PassResources, name: string) -> (ResolvedTexture, bool) {
	if texture, found := res.textures[name]; found {
		return texture, found
	}
	if res.scope != .GLOBAL {
		scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(res.scope), res.instance_idx)
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
		scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(res.scope), res.instance_idx)
		if buffer, found := res.buffers[scoped]; found {
			return buffer, found
		}
	}
	return {}, false
}
