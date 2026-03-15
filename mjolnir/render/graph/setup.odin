package render_graph

import "core:fmt"
import vk "vendor:vulkan"

// ============================================================================
// Resource Creation API (called during PassSetupProc)
// ============================================================================

create_texture :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: TextureDesc,
) -> TextureId {
  return _add_texture(setup, builder, name, desc)
}

create_texture_cube :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: TextureCubeDesc,
) -> TextureId {
  return _add_texture_cube(setup, builder, name, desc)
}

create_buffer :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: BufferDesc,
) -> BufferId {
  return _add_buffer(setup, builder, name, desc)
}

register_external_texture :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: TextureDesc,
) -> TextureId {
  id := _add_texture(setup, builder, name, desc)
  builder.resources[id.index].is_external = true
  return id
}

register_external_buffer :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: BufferDesc,
) -> BufferId {
  id := _add_buffer(setup, builder, name, desc)
  builder.resources[id.index].is_external = true
  return id
}

@(private)
_add_texture :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: TextureDesc,
) -> TextureId {
  resolved_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)
  for decl, i in builder.resources {
    if decl.name == resolved_name {
      if _, ok := decl.desc.(TextureDesc); ok {
        if setup.pass_scope != .GLOBAL do delete(resolved_name)
        return TextureId{index = u32(i)}
      }
    }
  }
  append(
    &builder.resources,
    ResourceDecl{
      name         = resolved_name,
      desc         = desc,
      scope        = setup.pass_scope,
      instance_idx = setup.instance_idx,
    },
  )
  return TextureId{index = u32(len(builder.resources) - 1)}
}

@(private)
_add_texture_cube :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: TextureCubeDesc,
) -> TextureId {
  resolved_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)
  for decl, i in builder.resources {
    if decl.name == resolved_name {
      if _, ok := decl.desc.(TextureCubeDesc); ok {
        if setup.pass_scope != .GLOBAL do delete(resolved_name)
        return TextureId{index = u32(i)}
      }
    }
  }
  append(
    &builder.resources,
    ResourceDecl{
      name         = resolved_name,
      desc         = desc,
      scope        = setup.pass_scope,
      instance_idx = setup.instance_idx,
    },
  )
  return TextureId{index = u32(len(builder.resources) - 1)}
}

@(private)
_add_buffer :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  desc: BufferDesc,
) -> BufferId {
  resolved_name := scope_resource_name(name, setup.pass_scope, setup.instance_idx)
  for decl, i in builder.resources {
    if decl.name == resolved_name {
      if _, ok := decl.desc.(BufferDesc); ok {
        if setup.pass_scope != .GLOBAL do delete(resolved_name)
        return BufferId{index = u32(i)}
      }
    }
  }
  append(
    &builder.resources,
    ResourceDecl{
      name         = resolved_name,
      desc         = desc,
      scope        = setup.pass_scope,
      instance_idx = setup.instance_idx,
    },
  )
  return BufferId{index = u32(len(builder.resources) - 1)}
}

// ============================================================================
// Resource Lookup API
// ============================================================================

@(private)
_find_texture_same_scope :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
) -> (
  TextureId,
  bool,
) {
  if setup.pass_scope != .GLOBAL {
    scoped := fmt.tprintf(
      "%s_%s_%d",
      name,
      _scope_suffix(setup.pass_scope),
      setup.instance_idx,
    )
    for decl, i in builder.resources {
      if decl.name == scoped {
        switch _ in decl.desc {
        case TextureDesc, TextureCubeDesc:
          return TextureId{index = u32(i)}, true
        case BufferDesc:
        }
      }
    }
  }
  for decl, i in builder.resources {
    if decl.name == name {
      switch _ in decl.desc {
      case TextureDesc, TextureCubeDesc:
        return TextureId{index = u32(i)}, true
      case BufferDesc:
      }
    }
  }
  return TextureId{}, false
}

@(private)
_find_texture_cross_scope :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  scope: PassScope,
  instance_idx: u32,
) -> (
  TextureId,
  bool,
) {
  scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(scope), instance_idx)
  for decl, i in builder.resources {
    if decl.name == scoped {
      switch _ in decl.desc {
      case TextureDesc, TextureCubeDesc:
        return TextureId{index = u32(i)}, true
      case BufferDesc:
      }
    }
  }
  return TextureId{}, false
}

find_texture :: proc {
  _find_texture_same_scope,
  _find_texture_cross_scope,
}

@(private)
_find_buffer_same_scope :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
) -> (
  BufferId,
  bool,
) {
  if setup.pass_scope != .GLOBAL {
    scoped := fmt.tprintf(
      "%s_%s_%d",
      name,
      _scope_suffix(setup.pass_scope),
      setup.instance_idx,
    )
    for decl, i in builder.resources {
      if decl.name == scoped {
        if _, ok := decl.desc.(BufferDesc); ok {
          return BufferId{index = u32(i)}, true
        }
      }
    }
  }
  for decl, i in builder.resources {
    if decl.name == name {
      if _, ok := decl.desc.(BufferDesc); ok {
        return BufferId{index = u32(i)}, true
      }
    }
  }
  return BufferId{}, false
}

@(private)
_find_buffer_cross_scope :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  name: string,
  scope: PassScope,
  instance_idx: u32,
) -> (
  BufferId,
  bool,
) {
  scoped := fmt.tprintf("%s_%s_%d", name, _scope_suffix(scope), instance_idx)
  for decl, i in builder.resources {
    if decl.name == scoped {
      if _, ok := decl.desc.(BufferDesc); ok {
        return BufferId{index = u32(i)}, true
      }
    }
  }
  return BufferId{}, false
}

find_buffer :: proc {
  _find_buffer_same_scope,
  _find_buffer_cross_scope,
}

// ============================================================================
// Dependency Declaration API
// ============================================================================

read_texture :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  id: TextureId,
  frame_offset := FrameOffset.CURRENT,
) {_declare_access(setup, builder, id.index, .READ, frame_offset)}
write_texture :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  id: TextureId,
  frame_offset := FrameOffset.CURRENT,
) {_declare_access(setup, builder, id.index, .WRITE, frame_offset)}
read_buffer :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  id: BufferId,
  frame_offset := FrameOffset.CURRENT,
) {_declare_access(setup, builder, id.index, .READ, frame_offset)}
write_buffer :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  id: BufferId,
  frame_offset := FrameOffset.CURRENT,
) {_declare_access(setup, builder, id.index, .WRITE, frame_offset)}
read_write_texture :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  id: TextureId,
  frame_offset := FrameOffset.CURRENT,
) {_declare_access(setup, builder, id.index, .READ_WRITE, frame_offset)}
read_write_buffer :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  id: BufferId,
  frame_offset := FrameOffset.CURRENT,
) {_declare_access(setup, builder, id.index, .READ_WRITE, frame_offset)}

@(private)
_declare_access :: proc(
  setup: ^PassSetup,
  builder: ^PassBuilder,
  index: u32,
  access: AccessMode,
  frame_offset: FrameOffset,
) {
  if int(index) >= len(builder.resources) do return
  name := builder.resources[index].name
  acc := ResourceAccess {
    resource_name = name,
    frame_offset  = frame_offset,
    access_mode   = access,
  }
  if access != .WRITE do append(&builder.reads, acc)
  if access != .READ do append(&builder.writes, acc)
}

// ============================================================================
// Batch Dependency Declaration API
// ============================================================================

reads_textures :: proc(setup: ^PassSetup, builder: ^PassBuilder, ids: ..TextureId) {for id in ids do read_texture(setup, builder, id)}
writes_textures :: proc(setup: ^PassSetup, builder: ^PassBuilder, ids: ..TextureId) {for id in ids do write_texture(setup, builder, id)}
reads_buffers :: proc(setup: ^PassSetup, builder: ^PassBuilder, ids: ..BufferId) {for id in ids do read_buffer(setup, builder, id)}
writes_buffers :: proc(setup: ^PassSetup, builder: ^PassBuilder, ids: ..BufferId) {for id in ids do write_buffer(setup, builder, id)}

// ============================================================================
// Helper Functions
// ============================================================================

@(private)
_scope_suffix :: proc(scope: PassScope) -> string {
  switch scope {
  case .PER_CAMERA:
    return "cam"
  case .PER_POINT_LIGHT, .PER_SPOT_LIGHT, .PER_DIRECTIONAL_LIGHT:
    return "light"
  case .GLOBAL:
    return ""
  }
  return ""
}

@(private)
scope_resource_name :: proc(
  name: string,
  scope: PassScope,
  instance_idx: u32,
) -> string {
  switch scope {
  case .GLOBAL:
    return name
  case .PER_CAMERA:
    return fmt.aprintf("%s_cam_%d", name, instance_idx)
  case .PER_POINT_LIGHT, .PER_SPOT_LIGHT, .PER_DIRECTIONAL_LIGHT:
    return fmt.aprintf("%s_light_%d", name, instance_idx)
  }
  return name
}

// ============================================================================
// Execution-Phase Resource Access API
// ============================================================================

get_texture :: proc(
  res: ^PassResources,
  name: string,
) -> (
  ResolvedTexture,
  bool,
) {
  if texture, found := res.textures[name]; found {
    return texture, found
  }
  if res.scope != .GLOBAL {
    scoped := fmt.tprintf(
      "%s_%s_%d",
      name,
      _scope_suffix(res.scope),
      res.instance_idx,
    )
    if texture, found := res.textures[scoped]; found {
      return texture, found
    }
  }
  return {}, false
}

get_buffer :: proc(
  res: ^PassResources,
  name: string,
) -> (
  ResolvedBuffer,
  bool,
) {
  if buffer, found := res.buffers[name]; found {
    return buffer, found
  }
  if res.scope != .GLOBAL {
    scoped := fmt.tprintf(
      "%s_%s_%d",
      name,
      _scope_suffix(res.scope),
      res.instance_idx,
    )
    if buffer, found := res.buffers[scoped]; found {
      return buffer, found
    }
  }
  return {}, false
}
