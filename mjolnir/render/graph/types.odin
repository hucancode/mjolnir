package render_graph

import vk "vendor:vulkan"

// ============================================================================
// Core Enums
// ============================================================================

PassScope :: enum {
	GLOBAL,     // Runs once per frame (e.g., particle simulation, UI)
	PER_CAMERA, // Runs once per camera (e.g., geometry, lighting)
	PER_LIGHT,  // Runs once per light (e.g., shadow mapping)
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

ResourceType :: enum {
	BUFFER,
	TEXTURE_2D,
	TEXTURE_CUBE,
}

// ============================================================================
// Typed Resource Handles (Compile-time Safety)
// ============================================================================

// Opaque resource identifier with phantom type parameter
ResourceId :: struct($T: typeid) {
	index: u32,
}

// Convenience aliases for common resource types
TextureId :: ResourceId(TextureDesc)
BufferId :: ResourceId(BufferDesc)

// ============================================================================
// Resource Descriptors
// ============================================================================

TextureDesc :: struct {
	width:       u32,
	height:      u32,
	format:      vk.Format,
	usage:       vk.ImageUsageFlags,
	aspect:      vk.ImageAspectFlags,
	is_cube:     bool,
	is_external: bool, // If true, not allocated by graph
}

BufferDesc :: struct {
	size:        vk.DeviceSize,
	usage:       vk.BufferUsageFlags,
	is_external: bool, // If true, not allocated by graph
}

// ============================================================================
// Declaration Layer (Input to Compilation)
// ============================================================================

// Resource declaration created during pass setup
ResourceDecl :: struct {
	name:         string,
	type:         ResourceType,
	texture_desc: TextureDesc,
	buffer_desc:  BufferDesc,
	scope:        PassScope, // Scope where resource was created
	instance_idx: u32,       // Instance index within scope (for PER_CAMERA/PER_LIGHT)
}

// Pass setup callback - called during compilation to declare resources
PassSetupProc :: #type proc(setup: ^PassSetup, user_data: rawptr)

// Pass execution callback - called during graph execution
PassExecuteProc :: #type proc(
	resources: ^PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
)

// Pass declaration (template, not runtime instance)
PassDecl :: struct {
	name:      string,
	scope:     PassScope,
	queue:     QueueType,
	setup:     PassSetupProc,
	execute:   PassExecuteProc,
	user_data: rawptr,
}

// ============================================================================
// Setup-Phase Types
// ============================================================================

// Context passed to PassSetupProc
PassSetup :: struct {
	pass_name:     string,
	pass_scope:    PassScope,
	instance_idx:  u32, // Instance index (0 for GLOBAL, camera/light index for scoped)

	// Internal state (managed by compiler)
	resources:     [dynamic]ResourceDecl,
	reads:         [dynamic]ResourceAccess,
	writes:        [dynamic]ResourceAccess,
}

ResourceAccess :: struct {
	resource_name: string,
	frame_offset:  FrameOffset,
	access_mode:   AccessMode,
}

// ============================================================================
// Runtime Layer (Output from Compilation)
// ============================================================================

// Runtime pass instance (one PassDecl can create N PassInstances)
PassInstance :: struct {
	name:       string,
	scope:      PassScope,
	instance:   u32,      // Instance index within scope
	queue:      QueueType,
	execute:    PassExecuteProc,
	user_data:  rawptr,

	// Dependencies
	reads:      [dynamic]ResourceAccess,
	writes:     [dynamic]ResourceAccess,
}

// Runtime resource instance
ResourceInstance :: struct {
	name:          string,
	type:          ResourceType,
	scope:         PassScope,
	instance_idx:  u32,

	// Physical resources (allocated by graph)
	// Array length = 1 (CURRENT only) or FRAMES_IN_FLIGHT (NEXT/PREV used)
	buffers:       [dynamic]vk.Buffer,
	buffer_memory: [dynamic]vk.DeviceMemory,
	buffer_size:   vk.DeviceSize,

	images:        [dynamic]vk.Image,
	image_views:   [dynamic]vk.ImageView,
	image_memory:  [dynamic]vk.DeviceMemory,

	// External resources (registered, not allocated)
	external_buffer:     vk.Buffer,
	external_image:      vk.Image,
	external_image_view: vk.ImageView,

	// Descriptor
	texture_desc:  TextureDesc,
	buffer_desc:   BufferDesc,
}

// ============================================================================
// Execution-Phase Types
// ============================================================================

// Resolved resources passed to PassExecuteProc
PassResources :: struct {
	textures: map[string]ResolvedTexture,
	buffers:  map[string]ResolvedBuffer,

	// Instance context (for PER_CAMERA/PER_LIGHT passes)
	instance_idx:   u32,    // Instance index (0, 1, 2...)
	camera_handle:  u32,    // Actual camera handle (valid for PER_CAMERA passes)
	light_handle:   u32,    // Actual light handle (valid for PER_LIGHT passes)
}

ResolvedTexture :: struct {
	image:  vk.Image,
	view:   vk.ImageView,
	format: vk.Format,
	width:  u32,
	height: u32,
}

ResolvedBuffer :: struct {
	buffer: vk.Buffer,
	size:   vk.DeviceSize,
}

// Pipeline barrier
Barrier :: struct {
	// Resource
	buffer:     vk.Buffer,
	image:      vk.Image,

	// Synchronization
	src_access: vk.AccessFlags,
	dst_access: vk.AccessFlags,
	src_stage:  vk.PipelineStageFlags,
	dst_stage:  vk.PipelineStageFlags,

	// Image barriers only
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
	aspect:     vk.ImageAspectFlags,
}

// ============================================================================
// Compilation Types
// ============================================================================

CompileContext :: struct {
	num_cameras:      int,
	num_lights:       int,
	frames_in_flight: int,
	gctx:             rawptr, // ^gpu.GPUContext (avoid import)

	// Handle mappings: instance_idx -> actual handle
	// These arrays map sequential indices (0, 1, 2...) to actual camera/light handles
	camera_handles:   []u32,  // instance_idx -> camera handle
	light_handles:    []u32,  // instance_idx -> light node handle
}

CompileError :: enum {
	NONE,
	CYCLE_DETECTED,
	DANGLING_READ,         // Pass reads resource that no one writes
	TYPE_MISMATCH,         // TextureId used with buffer, etc.
	FRAME_OFFSET_INVALID,  // PREV used on resource never written with NEXT
	ALLOCATION_FAILED,
}

// ============================================================================
// Opaque IDs for Runtime Instances
// ============================================================================

PassInstanceId :: distinct u32
ResourceInstanceId :: distinct u32
