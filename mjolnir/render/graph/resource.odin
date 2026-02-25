package render_graph

import vk "vendor:vulkan"

// Resource scope determines instantiation behavior
ResourceScope :: enum {
  GLOBAL, // Shared across all cameras/lights
  PER_FRAME, // Per-frame buffered
  PER_CAMERA, // Per-camera instance
  PER_LIGHT, // Per-light instance
}

// Resource type classification
ResourceType :: enum {
  BUFFER,
  TEXTURE_2D,
  TEXTURE_CUBE,
  DEPTH_TEXTURE,
}

// Unified index for all render-graph resources.
// Values are grouped by scope to allow O(1) offset computation.
ResourceIndex :: enum u16 {
  // GLOBAL
  NODE_DATA_BUFFER = 0,
  MESH_DATA_BUFFER,
  MATERIAL_BUFFER,
  LIGHTS_BUFFER,
  EMITTER_BUFFER,
  FORCEFIELD_BUFFER,
  SPRITE_BUFFER,
  PARTICLE_BUFFER,
  COMPACT_PARTICLE_BUFFER,
  DRAW_COMMAND_BUFFER,
  POST_PROCESS_IMAGE_0,
  POST_PROCESS_IMAGE_1,

  // PER_FRAME
  _PER_FRAME_START,
  BONE_BUFFER = _PER_FRAME_START,
  CAMERA_BUFFER,
  UI_VERTEX_BUFFER,
  UI_INDEX_BUFFER,

  // PER_CAMERA
  _PER_CAMERA_START,
  CAMERA_DEPTH = _PER_CAMERA_START,
  CAMERA_GBUFFER_POSITION,
  CAMERA_GBUFFER_NORMAL,
  CAMERA_GBUFFER_ALBEDO,
  CAMERA_GBUFFER_METALLIC_ROUGHNESS,
  CAMERA_GBUFFER_EMISSIVE,
  CAMERA_FINAL_IMAGE,
  CAMERA_DEPTH_PYRAMID,
  CAMERA_OPAQUE_DRAW_COMMANDS,
  CAMERA_OPAQUE_DRAW_COUNT,
  CAMERA_TRANSPARENT_DRAW_COMMANDS,
  CAMERA_TRANSPARENT_DRAW_COUNT,
  CAMERA_WIREFRAME_DRAW_COMMANDS,
  CAMERA_WIREFRAME_DRAW_COUNT,
  CAMERA_RANDOM_COLOR_DRAW_COMMANDS,
  CAMERA_RANDOM_COLOR_DRAW_COUNT,
  CAMERA_LINE_STRIP_DRAW_COMMANDS,
  CAMERA_LINE_STRIP_DRAW_COUNT,
  CAMERA_SPRITE_DRAW_COMMANDS,
  CAMERA_SPRITE_DRAW_COUNT,

  // PER_LIGHT
  _PER_LIGHT_START,
  SHADOW_MAP = _PER_LIGHT_START,
  SHADOW_DRAW_COMMANDS,
  SHADOW_DRAW_COUNT,

  // Reserved dynamic range
  _DYNAMIC_START,
}

resource_scope_for_index :: proc(idx: ResourceIndex) -> ResourceScope {
  if idx < ._PER_FRAME_START do return .GLOBAL
  if idx < ._PER_CAMERA_START do return .PER_FRAME
  if idx < ._PER_LIGHT_START do return .PER_CAMERA
  if idx < ._DYNAMIC_START do return .PER_LIGHT
  return .GLOBAL
}

resource_index_offset :: proc(idx: ResourceIndex) -> u16 {
  switch resource_scope_for_index(idx) {
  case .GLOBAL:
    return u16(idx)
  case .PER_FRAME:
    return u16(idx) - u16(ResourceIndex._PER_FRAME_START)
  case .PER_CAMERA:
    return u16(idx) - u16(ResourceIndex._PER_CAMERA_START)
  case .PER_LIGHT:
    return u16(idx) - u16(ResourceIndex._PER_LIGHT_START)
  }
  return 0
}

resource_type_for_index :: proc(idx: ResourceIndex) -> ResourceType {
  #partial switch idx {
  case .POST_PROCESS_IMAGE_0,
       .POST_PROCESS_IMAGE_1,
       .CAMERA_GBUFFER_POSITION,
       .CAMERA_GBUFFER_NORMAL,
       .CAMERA_GBUFFER_ALBEDO,
       .CAMERA_GBUFFER_METALLIC_ROUGHNESS,
       .CAMERA_GBUFFER_EMISSIVE,
       .CAMERA_FINAL_IMAGE,
       .CAMERA_DEPTH_PYRAMID:
    return .TEXTURE_2D
  case .CAMERA_DEPTH, .SHADOW_MAP:
    return .DEPTH_TEXTURE
  }
  return .BUFFER
}

ResourceRef :: struct {
  index:       ResourceIndex,
  scope_index: u32,
}

ResourceKey :: struct {
  index:       ResourceIndex,
  scope_index: u32,
}

FixedResourceTemplate :: struct {
  scope_index: u32,
}

PassScopedResourceTemplate :: struct {
}

ResourceTemplateInstance :: union {
  FixedResourceTemplate,
  PassScopedResourceTemplate,
}

ResourceRefTemplate :: struct {
  index:    ResourceIndex,
  instance: ResourceTemplateInstance,
}

// Resource format descriptors
ResourceFormat :: union {
  BufferFormat,
  TextureFormat,
}

BufferFormat :: struct {
  element_size:  uint,
  element_count: uint,
  usage:         vk.BufferUsageFlags,
}

TextureFormat :: struct {
  width, height: u32,
  format:        vk.Format,
  usage:         vk.ImageUsageFlags,
  mip_levels:    u32,
}

// Type-safe resource handles (like Frostbite's FrameGraphResources)
Resource :: union {
  Buffer,
  Texture,
  DepthTexture,
}

Buffer :: struct {
  buffer:         vk.Buffer,
  size:           vk.DeviceSize,
  descriptor_set: vk.DescriptorSet, // For bindless access
}

Texture :: struct {
  image:  vk.Image,
  view:   vk.ImageView,
  extent: vk.Extent2D,
  format: vk.Format,
  index:  u32,
}

DepthTexture :: struct {
  image:  vk.Image,
  view:   vk.ImageView,
  extent: vk.Extent2D,
  index:  u32,
}

ResourceIndexResolveProc :: #type proc(
  render_manager: rawptr,
  idx: ResourceIndex,
  frame_index, scope_index: u32,
) -> (
  Resource,
  bool,
)

GraphExecutionContext :: struct {
	render_manager:         rawptr, // ^render.Manager (to avoid circular import)
	frame_payload:          rawptr, // ^render.FrameGraphExecutionPayload
	resolve_resource_index: ResourceIndexResolveProc,
}

// Resource descriptor - defines a resource in the graph
ResourceDescriptor :: struct {
  ref:          ResourceRef,
  type:         ResourceType,
  format:       ResourceFormat,
  is_transient: bool, // Transient vs imported resource
}

// ============================================================================
// PUBLIC API - TEMPLATE INSTANTIATION
// ============================================================================

resource_ref_from_template :: proc(
  template: ResourceRefTemplate,
  pass_scope_index: u32,
) -> ResourceRef {
  scope_index := u32(0)
  switch instance in template.instance {
  case FixedResourceTemplate:
    scope_index = instance.scope_index
  case PassScopedResourceTemplate:
    scope_index = pass_scope_index
  }
  return ResourceRef {
    index = template.index,
    scope_index = scope_index,
  }
}

resource_ref_matches :: proc(a, b: ResourceRef) -> bool {
  return resource_ref_key(a) == resource_ref_key(b)
}

resource_ref_type :: proc(ref: ResourceRef) -> ResourceType {
  return resource_type_for_index(ref.index)
}

resource_ref_scope :: proc(ref: ResourceRef) -> ResourceScope {
  return resource_scope_for_index(ref.index)
}

resource_ref_scope_index :: proc(ref: ResourceRef) -> u32 {
  return resource_ref_key(ref).scope_index
}

resource_ref_key :: proc(ref: ResourceRef) -> ResourceKey {
  scope_index := ref.scope_index
  scope := resource_scope_for_index(ref.index)
  if scope == .GLOBAL || scope == .PER_FRAME {
    scope_index = 0
  }
  return ResourceKey{index = ref.index, scope_index = scope_index}
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_infer_resource_type :: proc(format: ResourceFormat) -> ResourceType {
  switch _ in format {
  case BufferFormat:
    return .BUFFER
  case TextureFormat:
    tex_fmt := format.(TextureFormat)
    if _is_depth_format(tex_fmt.format) {
      return .DEPTH_TEXTURE
    }
    return .TEXTURE_2D
  }
  return .BUFFER
}

@(private)
_is_depth_format :: proc(format: vk.Format) -> bool {
  #partial switch format {
  case .D16_UNORM,
       .D32_SFLOAT,
       .D16_UNORM_S8_UINT,
       .D24_UNORM_S8_UINT,
       .D32_SFLOAT_S8_UINT:
    return true
  }
  return false
}
