package render_graph

import vk "vendor:vulkan"

// ============================================================================
// Core Enums
// ============================================================================

PassScope :: enum {
  GLOBAL,
  PER_CAMERA,
  PER_POINT_LIGHT,
  PER_SPOT_LIGHT,
  PER_DIRECTIONAL_LIGHT,
}

QueueType :: enum {
  GRAPHICS,
  COMPUTE,
}

FrameOffset :: enum i8 {
  PREV    = -1,
  CURRENT = 0,
  NEXT    = 1,
}

AccessMode :: enum {
  READ,
  WRITE,
  READ_WRITE,
}

// ============================================================================
// Typed Resource Handles (Compile-time Safety)
// ============================================================================

ResourceId :: struct($T: typeid) {
  index: u32,
}

TextureId :: ResourceId(TextureDesc)
BufferId :: ResourceId(BufferDesc)

// ============================================================================
// Resource Descriptors (public — passed by callers at setup time)
// ============================================================================

TextureDesc :: struct {
  width:         u32,
  height:        u32,
  format:        vk.Format,
  usage:         vk.ImageUsageFlags,
  aspect:        vk.ImageAspectFlags,
  double_buffer: bool, // Allocate one variant per frame-in-flight
}

// Cube faces are always square; no double_buffer (cube shadow maps are not double-buffered).
TextureCubeDesc :: struct {
  width:  u32,
  format: vk.Format,
  usage:  vk.ImageUsageFlags,
  aspect: vk.ImageAspectFlags,
}

BufferDesc :: struct {
  size:  vk.DeviceSize,
  usage: vk.BufferUsageFlags,
}

// ============================================================================
// Runtime Resource Types
//
// Each struct stores the descriptor fields alongside the GPU handles so the
// resource type is encoded exactly once — in the union discriminant of
// ResourceInstance.data.  No separate ResourceType enum is needed.
// ============================================================================

ResourceTexture :: struct {
  // Descriptor
  width:               u32,
  height:              u32,
  format:              vk.Format,
  usage:               vk.ImageUsageFlags,
  aspect:              vk.ImageAspectFlags,
  double_buffer:       bool,
  // Allocated handles (len == 1 or FRAMES_IN_FLIGHT)
  images:              [dynamic]vk.Image,
  image_views:         [dynamic]vk.ImageView,
  // Transmute to gpu.Texture2DHandle for bindless shader access
  texture_handle_bits: [dynamic]u64,
  // External handles (used when ResourceInstance.is_external)
  external_image:      vk.Image,
  external_image_view: vk.ImageView,
}

ResourceTextureCube :: struct {
  // Descriptor (no height — cube faces are always square)
  width:               u32,
  format:              vk.Format,
  usage:               vk.ImageUsageFlags,
  aspect:              vk.ImageAspectFlags,
  // Allocated handles
  images:              [dynamic]vk.Image,
  image_views:         [dynamic]vk.ImageView,
  // Transmute to gpu.TextureCubeHandle for bindless shader access
  texture_handle_bits: [dynamic]u64,
  // External handles
  external_image:      vk.Image,
  external_image_view: vk.ImageView,
}

ResourceBuffer :: struct {
  // Descriptor
  size:          vk.DeviceSize,
  usage:         vk.BufferUsageFlags,
  // Allocated handles
  buffers:       [dynamic]vk.Buffer,
  buffer_memory: [dynamic]vk.DeviceMemory,
  // External handle
  external:      vk.Buffer,
}

// ============================================================================
// Declaration Layer (Input to Compilation)
// ============================================================================

// Resource declaration created during pass setup.
// The desc union encodes the resource type — no separate type field needed.
ResourceDecl :: struct {
  name:         string,
  desc:         union {
    TextureDesc,
    TextureCubeDesc,
    BufferDesc,
  },
  scope:        PassScope,
  instance_idx: u32,
  is_external:  bool,
}

LightKind :: enum u8 {
  POINT,
  SPOT,
  DIRECTIONAL,
}

PassSetupProc :: #type proc(setup: ^PassSetup, builder: ^PassBuilder)

PassExecuteProc :: #type proc(
  ctx: rawptr,
  resources: ^PassResources,
  cmd: vk.CommandBuffer,
  frame_index: u32,
)

PassDecl :: struct {
  name:    string,
  scope:   PassScope,
  queue:   QueueType,
  setup:   PassSetupProc,
  execute: PassExecuteProc,
}

// ============================================================================
// Setup-Phase Types
// ============================================================================

// Mutable accumulation state — owned and managed by compile() per-pass.
PassBuilder :: struct {
  resources: [dynamic]ResourceDecl,
  reads:     [dynamic]ResourceAccess,
  writes:    [dynamic]ResourceAccess,
}

// Pure read-only context — topology hints and pass identity.
PassSetup :: struct {
  pass_name:        string,
  pass_scope:       PassScope,
  instance_idx:     u32,

  // Topology hints propagated from CompileContext (read-only)
  num_cameras:      int,
  num_lights:       int,
  camera_extents:   []vk.Extent2D,
  light_kinds:      []LightKind,
  swapchain_format: vk.Format,
}

ResourceAccess :: struct {
  resource_name: string,
  frame_offset:  FrameOffset,
  access_mode:   AccessMode,
  version:       u32,
}

// ============================================================================
// Runtime Layer (Output from Compilation)
// ============================================================================

PassInstance :: struct {
  name:     string,
  scope:    PassScope,
  instance: u32,
  queue:    QueueType,
  execute:  PassExecuteProc,

  reads:    [dynamic]ResourceAccess,
  writes:   [dynamic]ResourceAccess,
}

// Runtime resource instance.
// data is the single source of truth for the resource type — switch on it
// instead of keeping a separate type discriminant.
ResourceInstance :: struct {
  name:         string,
  scope:        PassScope,
  instance_idx: u32,
  is_external:  bool,
  is_alias:     bool,
  alias_target: ResourceInstanceId,
  data:         union {
    ResourceTexture,
    ResourceTextureCube,
    ResourceBuffer,
  },
}

// ============================================================================
// Execution-Phase Types
// ============================================================================

PassResources :: struct {
  textures:      map[string]ResolvedTexture,
  buffers:       map[string]ResolvedBuffer,

  scope:         PassScope,
  instance_idx:  u32,
  camera_handle: u32,
  light_handle:  u32,
}

ResolvedTexture :: struct {
  image:       vk.Image,
  view:        vk.ImageView,
  handle_bits: u64,
}

ResolvedBuffer :: struct {
  buffer: vk.Buffer,
}

Barrier :: struct {
  resource_id:  ResourceInstanceId,
  frame_offset: FrameOffset,

  src_access:   vk.AccessFlags,
  dst_access:   vk.AccessFlags,
  src_stage:    vk.PipelineStageFlags,
  dst_stage:    vk.PipelineStageFlags,

  // Image barriers only (zero for buffer barriers)
  old_layout:   vk.ImageLayout,
  new_layout:   vk.ImageLayout,
  aspect:       vk.ImageAspectFlags,
}

// ============================================================================
// Compilation Types
// ============================================================================

CompileContext :: struct {
  num_cameras:      int,
  num_lights:       int,
  frames_in_flight: int,

  camera_handles:   []u32,
  light_handles:    []u32,

  camera_extents:   []vk.Extent2D,
  light_kinds:      []LightKind,
  swapchain_format: vk.Format,
}

CompileError :: enum {
  NONE,
  CYCLE_DETECTED,
  DANGLING_READ,
  TYPE_MISMATCH,
  FRAME_OFFSET_INVALID,
  ALLOCATION_FAILED,
}

// ============================================================================
// Graph Execution Iterator
// ============================================================================

GraphPassIterator :: struct {
  _graph:        ^Graph,
  _frame_index:  u32,
  _graphics_cmd: vk.CommandBuffer,
  _compute_cmd:  vk.CommandBuffer,
  _pass_idx:     int,
  resources:     PassResources,
  cmd:           vk.CommandBuffer,
}

// ============================================================================
// Opaque IDs for Runtime Instances
// ============================================================================

PassInstanceId :: distinct u32
ResourceInstanceId :: distinct u32
