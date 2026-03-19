package render_graph

import "../../gpu"
import "core:slice"
import vk "vendor:vulkan"

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

ResourceId :: struct($T: typeid) {
  index: u32,
}

TextureId :: ResourceId(TextureDesc)
BufferId :: ResourceId(BufferDesc)

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

// ============================================================================
// Declarative Resource Spec Types (pure-static declaration system)
// ============================================================================

// Sentinels for template expansion
CameraExtent    :: struct{} // expand to ctx.camera_extents[instance_idx]
SwapchainFormat :: struct{} // expand to ctx.swapchain_format

SizeSpec           :: union {u32, CameraExtent}
FormatSpec         :: union {vk.Format, SwapchainFormat}
DoubleBufferPolicy :: enum {
  NO,
  YES,
  WHEN_SECONDARY, // double_buffer = instance_idx > 0
}

// Scope reference for cross-scope resource access
SameScope  :: struct{}
CrossScope :: struct {
  scope:    PassScope,
  instance: u32,
}
AllOfScope :: struct {
  scope: PassScope,
}

ScopeRef :: union {SameScope, CrossScope, AllOfScope}

// Descriptor templates (parallel to TextureDesc/BufferDesc but with template fields)
TextureDescSpec :: struct {
  width:         SizeSpec,
  height:        SizeSpec,
  format:        FormatSpec,
  usage:         vk.ImageUsageFlags,
  aspect:        vk.ImageAspectFlags,
  double_buffer: DoubleBufferPolicy,
}
TextureCubeDescSpec :: struct {
  width:  u32,
  format: vk.Format,
  usage:  vk.ImageUsageFlags,
  aspect: vk.ImageAspectFlags,
}
BufferDescSpec :: struct {
  size:  vk.DeviceSize,
  usage: vk.BufferUsageFlags,
}
ResourceDescSpec :: union {TextureDescSpec, TextureCubeDescSpec, BufferDescSpec}

// Central declarative type — replaces all create/find/read/write calls.
// desc == nil means "find existing resource"; non-nil means "create/register".
// frame_offset and access default to .CURRENT and .READ (zero values).
ResourceSpec :: struct {
  name:         string,
  desc:         ResourceDescSpec,
  access:       AccessMode,
  is_external:  bool,
  scope_ref:    ScopeRef,    // nil = SameScope (zero value)
  frame_offset: FrameOffset, // default .CURRENT (zero value)
}

PassExecuteProc :: #type proc(
  ctx: rawptr,
  resources: ^PassResources,
  cmd: vk.CommandBuffer,
  frame_index: u32,
)

PassDecl :: struct {
  name:      string,
  scope:     PassScope,
  queue:     QueueType,
  resources: []ResourceSpec,
  execute:   PassExecuteProc,
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
  graph:        ^Graph,
  frame_index:  u32,
  graphics_cmd: vk.CommandBuffer,
  compute_cmd:  vk.CommandBuffer,
  pass_idx:     int,
  resources:    PassResources,
  cmd:          vk.CommandBuffer,
}

PassInstanceId :: distinct u32
ResourceInstanceId :: distinct u32
// ============================================================================
// Graph - Compiled Runtime Representation
// ============================================================================

// Graph contains ONLY compiled runtime data, no declarations
// This is the output of compile() and input to execute()
Graph :: struct {
  // Runtime instances (instantiated from PassDecl templates)
  pass_instances:     [dynamic]PassInstance,
  resource_instances: [dynamic]ResourceInstance,

  // Execution order (topologically sorted pass instance IDs)
  sorted_passes:      []PassInstanceId,

  // Barriers to emit before each pass
  barriers:           map[PassInstanceId][dynamic]Barrier,

  // Lookup tables (name -> instance ID)
  resource_by_name:   map[string]ResourceInstanceId,

  // Handle mappings: instance_idx -> actual handle
  camera_handles:     []u32, // Maps instance index to camera handle
  light_handles:      []u32, // Maps instance index to light node handle

  // Compilation metadata
  frames_in_flight:   int,
}

// ============================================================================
// Graph Lifecycle
// ============================================================================

@(private = "package")
init :: proc(graph: ^Graph, frames_in_flight: int) {
  graph.pass_instances = make([dynamic]PassInstance)
  graph.resource_instances = make([dynamic]ResourceInstance)
  graph.barriers = make(map[PassInstanceId][dynamic]Barrier)
  graph.resource_by_name = make(map[string]ResourceInstanceId)
  graph.frames_in_flight = frames_in_flight
}

destroy :: proc(
  graph: ^Graph,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
) {
  // Free pass instances (scoped names are heap-allocated)
  for &pass in graph.pass_instances {
    if pass.scope != .GLOBAL do delete(pass.name)
    delete(pass.reads)
    delete(pass.writes)
  }

  // Destroy all allocated GPU resources (also frees scoped resource names)
  for &res in graph.resource_instances {
    destroy_resource(&res, gctx, tm)
  }

  // Free barriers
  for _, barrier_list in graph.barriers {
    delete(barrier_list)
  }

  // Free containers
  delete(graph.pass_instances)
  delete(graph.resource_instances)
  delete(graph.barriers)
  delete(graph.resource_by_name)

  if graph.sorted_passes != nil {
    delete(graph.sorted_passes)
  }

  // Free handle mappings
  if graph.camera_handles != nil {
    delete(graph.camera_handles)
  }
  if graph.light_handles != nil {
    delete(graph.light_handles)
  }
}

// Reset graph for recompilation (keeps allocated GPU resources)
@(private = "package")
reset :: proc(graph: ^Graph) {
  // Clear pass instances (scoped names are heap-allocated)
  for &pass in graph.pass_instances {
    if pass.scope != .GLOBAL do delete(pass.name)
    delete(pass.reads)
    delete(pass.writes)
  }
  clear(&graph.pass_instances)

  // Clear barriers
  for _, barrier_list in graph.barriers {
    delete(barrier_list)
  }
  clear(&graph.barriers)

  // Clear sorted passes
  if graph.sorted_passes != nil {
    delete(graph.sorted_passes)
    graph.sorted_passes = nil
  }

  // Clear lookup tables
  clear(&graph.resource_by_name)
}

// ============================================================================
// Resource Lifecycle
// ============================================================================

@(private = "package")
destroy_resource :: proc(
  res: ^ResourceInstance,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
) {
  // Free heap-allocated scoped names (non-GLOBAL resources have fmt.aprintf names)
  if res.scope != .GLOBAL do delete(res.name)

  // External resources are not owned by graph
  if res.is_external {return}

  // Delegate actual GPU deallocation to allocator (which imports gpu package)
  deallocate_resource(res, gctx, tm)
}

// ============================================================================
// Helper Functions
// ============================================================================

// Get resource instance by name (for runtime lookups)
@(private = "package")
find_resource_by_name :: proc(
  graph: ^Graph,
  name: string,
) -> (
  ResourceInstanceId,
  bool,
) {
  id, found := graph.resource_by_name[name]
  return id, found
}

// Get pass instance by ID
@(private = "package")
get_pass :: proc(graph: ^Graph, id: PassInstanceId) -> ^PassInstance {
  return &graph.pass_instances[id]
}

// Get resource instance by ID
@(private = "package")
get_resource :: proc(
  graph: ^Graph,
  id: ResourceInstanceId,
) -> ^ResourceInstance {
  return &graph.resource_instances[id]
}

// Add pass instance (called by compiler)
@(private = "package")
add_pass_instance :: proc(
  graph: ^Graph,
  pass: PassInstance,
) -> PassInstanceId {
  id := PassInstanceId(len(graph.pass_instances))
  append(&graph.pass_instances, pass)
  return id
}

// Add resource instance (called by compiler)
@(private = "package")
add_resource_instance :: proc(
  graph: ^Graph,
  res: ResourceInstance,
) -> ResourceInstanceId {
  id := ResourceInstanceId(len(graph.resource_instances))
  append(&graph.resource_instances, res)

  // Register in lookup table
  graph.resource_by_name[res.name] = id

  return id
}

// Set execution order (called by compiler after topological sort)
@(private = "package")
set_execution_order :: proc(graph: ^Graph, order: []PassInstanceId) {
  if graph.sorted_passes != nil {
    delete(graph.sorted_passes)
  }
  graph.sorted_passes = slice.clone(order)
}

// _needs_frame_variants returns a map of resource names that require per-frame
// variants (any pass reads or writes with a non-CURRENT frame offset).
// Caller is responsible for deleting the returned map.
@(private = "package")
_needs_frame_variants :: proc(graph: ^Graph) -> map[string]bool {
  result := make(map[string]bool, len(graph.resource_instances))
  for &pass in graph.pass_instances {
    for read in pass.reads {
      if read.frame_offset != .CURRENT {
        result[read.resource_name] = true
      }
    }
    for write in pass.writes {
      if write.frame_offset != .CURRENT {
        result[write.resource_name] = true
      }
    }
  }
  return result
}

// Add barrier before pass (called by barrier computation)
@(private = "package")
add_barrier :: proc(graph: ^Graph, pass_id: PassInstanceId, barrier: Barrier) {
  if pass_id not_in graph.barriers {
    graph.barriers[pass_id] = make([dynamic]Barrier)
  }
  append(&graph.barriers[pass_id], barrier)
}

is_compiled :: proc(graph: ^Graph) -> bool {
  return graph.sorted_passes != nil
}

// get_texture_handle returns the bindless handle bits for a named texture at the given frame.
// Returns (handle_bits, true) on success; (0, false) if not found or not a texture.
get_texture_handle :: proc(graph: ^Graph, name: string, frame_index: u32) -> (u64, bool) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return 0, false
  res := get_resource(graph, res_id)

  switch d in res.data {
  case ResourceTexture:
    if len(d.texture_handle_bits) == 0 do return 0, false
    return d.texture_handle_bits[int(frame_index) % len(d.texture_handle_bits)], true
  case ResourceTextureCube:
    if len(d.texture_handle_bits) == 0 do return 0, false
    return d.texture_handle_bits[int(frame_index) % len(d.texture_handle_bits)], true
  case ResourceBuffer:
    return 0, false
  }
  return 0, false
}

// ============================================================================
// External Resource Update API
// ============================================================================

update_external_texture :: proc(
  graph: ^Graph,
  name: string,
  image: vk.Image,
  view: vk.ImageView,
) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return
  res := get_resource(graph, res_id)
  switch &d in res.data {
  case ResourceTexture:
    d.external_image = image
    d.external_image_view = view
  case ResourceTextureCube:
    d.external_image = image
    d.external_image_view = view
  case ResourceBuffer:
  }
}

update_external_buffer :: proc(
  graph: ^Graph,
  name: string,
  buffer: vk.Buffer,
) {
  res_id, found := find_resource_by_name(graph, name)
  if !found do return
  res := get_resource(graph, res_id)
  switch &d in res.data {
  case ResourceBuffer:
    d.external = buffer
  case ResourceTexture, ResourceTextureCube:
  }
}

// ============================================================================
// Public API - Main Entry Points
// ============================================================================

build_graph :: proc(
  graph: ^Graph,
  pass_decls: []PassDecl,
  ctx: CompileContext,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
  loc := #caller_location,
) -> CompileError {
  if graph.sorted_passes != nil {
    destroy(graph, gctx, tm)
  }

  new_graph, err := compile(pass_decls, ctx, loc)
  if err != .NONE {
    return err
  }
  graph^ = new_graph

  err = allocate_resources(graph, gctx, tm, loc)
  if err != .NONE {
    destroy(graph, gctx, tm)
    return err
  }

  compute_barriers(graph)

  return .NONE
}

make_pass_iterator :: proc(
  graph: ^Graph,
  frame_index: u32,
  graphics_cmd: vk.CommandBuffer,
  compute_cmd: vk.CommandBuffer,
) -> GraphPassIterator {
  return GraphPassIterator {
    graph        = graph,
    frame_index  = frame_index,
    graphics_cmd = graphics_cmd,
    compute_cmd  = compute_cmd,
    pass_idx     = 0,
  }
}
