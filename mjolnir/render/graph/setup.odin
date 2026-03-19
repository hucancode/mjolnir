package render_graph

import "core:fmt"

// ============================================================================
// Helper Functions (used by compiler and executor)
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
