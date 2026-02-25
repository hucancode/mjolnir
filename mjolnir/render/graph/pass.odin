package render_graph

import vk "vendor:vulkan"

// Compiled pass instance identifier (internal graph index)
PassId :: distinct u32

// Application-defined pass template identifier
PassTemplateId :: distinct u32

// Pass scope determines instantiation behavior
PassScope :: enum {
  GLOBAL, // Runs once per frame
  PER_CAMERA, // Instantiated for each active camera
  PER_LIGHT, // Instantiated for each shadow-casting light
}

// Queue type for pass execution
QueueType :: enum {
  GRAPHICS,
  COMPUTE,
}

// Execute phase callback (like Frostbite's execute lambda)
PassExecuteProc :: #type proc(ctx: ^PassContext)

// Pass template - declares a pass type that can be instantiated
PassTemplate :: struct {
  id:               PassTemplateId, // Stable pass identifier provided by application
  scope:            PassScope,
  instance_indices: []u32, // Used for PER_CAMERA/PER_LIGHT instantiation
  queue:            QueueType,
  execute:          PassExecuteProc, // Execute phase: render with resolved resources

  // Declarative input/output lists (typed references).
  inputs:           []ResourceRefTemplate, // Resources this pass reads
  outputs:          []ResourceRefTemplate, // Resources this pass writes
}

// Compiled pass instance (after template instantiation)
PassInstance :: struct {
  template_id: PassTemplateId,
  scope_index: u32,
  queue:       QueueType,
  inputs:      [dynamic]ResourceKey,
  outputs:     [dynamic]ResourceKey,
  execute:     PassExecuteProc,
  is_valid:    bool,
}

// Pass execution context (like Frostbite's FrameGraphResources)
PassContext :: struct {
  graph:       ^Graph,
  exec_ctx:    ^GraphExecutionContext,
  resources:   map[ResourceKey]Resource,
  frame_index: u32,
  scope_index: u32, // Camera/light index
  cmd:         vk.CommandBuffer,
}
