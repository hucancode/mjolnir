package render_graph

import "core:fmt"

@(private)
normalize_resource_scope_index :: proc(
  idx: ResourceIndex,
  scope_index: u32,
) -> u32 {
  scope := resource_scope_for_index(idx)
  if scope == .GLOBAL || scope == .PER_FRAME {
    return 0
  }
  return scope_index
}

@(private)
_require_resource_type :: proc(idx: ResourceIndex, expected: ResourceType) {
  when ODIN_DEBUG {
    actual := resource_type_for_index(idx)
    assert(
      actual == expected,
      fmt.tprintf(
        "Resource index %v has type %v, expected %v",
        idx,
        actual,
        expected,
      ),
    )
  }
}

@(private)
_require_resource_scope :: proc(idx: ResourceIndex, expected: ResourceScope) {
  when ODIN_DEBUG {
    actual := resource_scope_for_index(idx)
    assert(
      actual == expected,
      fmt.tprintf(
        "Resource index %v has scope %v, expected %v",
        idx,
        actual,
        expected,
      ),
    )
  }
}

resolve_resource_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> (
  Resource,
  bool,
) {
  normalized_scope_index := normalize_resource_scope_index(idx, scope_index)
  if ctx == nil {
    return {}, false
  }
  key := ResourceKey {
    index       = idx,
    scope_index = normalized_scope_index,
  }
  if handle, ok := ctx.resources[key]; ok {
    return handle, true
  }
  return {}, false
}

resolve_buffer_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> (
  Buffer,
  bool,
) {
  handle, resolve_ok := resolve_resource_index(ctx, idx, scope_index)
  if !resolve_ok do return {}, false
  buffer_handle, type_ok := handle.(Buffer)
  return buffer_handle, type_ok
}

resolve_texture_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> (
  Texture,
  bool,
) {
  handle, resolve_ok := resolve_resource_index(ctx, idx, scope_index)
  if !resolve_ok do return {}, false
  texture_handle, type_ok := handle.(Texture)
  return texture_handle, type_ok
}

resolve_depth_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> (
  DepthTexture,
  bool,
) {
  handle, resolve_ok := resolve_resource_index(ctx, idx, scope_index)
  if !resolve_ok do return {}, false
  depth_handle, type_ok := handle.(DepthTexture)
  return depth_handle, type_ok
}

require_resource_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> Resource {
  handle, ok := resolve_resource_index(ctx, idx, scope_index)
  frame_index := u32(0)
  if ctx != nil {
    frame_index = ctx.frame_index
  }
  assert(
    ok,
    fmt.tprintf(
      "Missing resource index %v (scope=%d frame=%d)",
      idx,
      normalize_resource_scope_index(idx, scope_index),
      frame_index,
    ),
  )
  return handle
}

require_buffer_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> Buffer {
  handle, ok := resolve_buffer_index(ctx, idx, scope_index)
  frame_index := u32(0)
  if ctx != nil {
    frame_index = ctx.frame_index
  }
  assert(
    ok,
    fmt.tprintf(
      "Missing buffer index %v (scope=%d frame=%d)",
      idx,
      normalize_resource_scope_index(idx, scope_index),
      frame_index,
    ),
  )
  return handle
}

require_texture_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> Texture {
  handle, ok := resolve_texture_index(ctx, idx, scope_index)
  frame_index := u32(0)
  if ctx != nil {
    frame_index = ctx.frame_index
  }
  assert(
    ok,
    fmt.tprintf(
      "Missing texture index %v (scope=%d frame=%d)",
      idx,
      normalize_resource_scope_index(idx, scope_index),
      frame_index,
    ),
  )
  return handle
}

require_depth_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
  scope_index: u32 = 0,
) -> DepthTexture {
  handle, ok := resolve_depth_index(ctx, idx, scope_index)
  frame_index := u32(0)
  if ctx != nil {
    frame_index = ctx.frame_index
  }
  assert(
    ok,
    fmt.tprintf(
      "Missing depth index %v (scope=%d frame=%d)",
      idx,
      normalize_resource_scope_index(idx, scope_index),
      frame_index,
    ),
  )
  return handle
}

require_pass_resource_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
) -> Resource {
  scope_index := u32(0)
  if ctx != nil {
    scope_index = ctx.scope_index
  }
  return require_resource_index(ctx, idx, scope_index)
}

require_pass_buffer_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
) -> Buffer {
  _require_resource_type(idx, .BUFFER)
  scope_index := u32(0)
  if ctx != nil {
    scope_index = ctx.scope_index
  }
  return require_buffer_index(ctx, idx, scope_index)
}

require_pass_texture_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
) -> Texture {
  _require_resource_type(idx, .TEXTURE_2D)
  scope_index := u32(0)
  if ctx != nil {
    scope_index = ctx.scope_index
  }
  return require_texture_index(ctx, idx, scope_index)
}

require_pass_depth_index :: proc(
  ctx: ^PassContext,
  idx: ResourceIndex,
) -> DepthTexture {
  _require_resource_type(idx, .DEPTH_TEXTURE)
  scope_index := u32(0)
  if ctx != nil {
    scope_index = ctx.scope_index
  }
  return require_depth_index(ctx, idx, scope_index)
}

get_resource :: proc(ctx: ^PassContext, idx: ResourceIndex) -> Resource {
  return require_pass_resource_index(ctx, idx)
}

get_buffer :: proc(ctx: ^PassContext, idx: ResourceIndex) -> Buffer {
  return require_pass_buffer_index(ctx, idx)
}

get_texture :: proc(ctx: ^PassContext, idx: ResourceIndex) -> Texture {
  return require_pass_texture_index(ctx, idx)
}

get_depth :: proc(ctx: ^PassContext, idx: ResourceIndex) -> DepthTexture {
  return require_pass_depth_index(ctx, idx)
}

get_global :: proc(ctx: ^PassContext, idx: ResourceIndex) -> Resource {
  _require_resource_scope(idx, .GLOBAL)
  return require_resource_index(ctx, idx, 0)
}

get_per_frame :: proc(ctx: ^PassContext, idx: ResourceIndex) -> Resource {
  _require_resource_scope(idx, .PER_FRAME)
  return require_resource_index(ctx, idx, 0)
}

get_camera :: proc(
  ctx: ^PassContext,
  camera_index: u32,
  idx: ResourceIndex,
) -> Resource {
  _require_resource_scope(idx, .PER_CAMERA)
  return require_resource_index(ctx, idx, camera_index)
}

get_light :: proc(
  ctx: ^PassContext,
  light_index: u32,
  idx: ResourceIndex,
) -> Resource {
  _require_resource_scope(idx, .PER_LIGHT)
  return require_resource_index(ctx, idx, light_index)
}

get :: proc(ctx: ^PassContext, idx: ResourceIndex) -> Resource {
  return get_resource(ctx, idx)
}
