package render_graph

// Package render_graph implements a Frostbite-inspired frame graph for automatic
// resource dependency tracking and barrier insertion.
//
// The graph follows a three-phase execution model:
//
// SETUP PHASE:
//   1. graph_init() - Initialize empty graph
//   2. graph_register_resource() - Declare all resources (buffers, textures)
//   3. Build runtime templates with graph_make_pass_template()
//   4. Repeat step 3 each frame (resources are registered once)
//
// COMPILE PHASE:
//   5. graph_compile() - Build execution order, pre-resolve resource handles, compute barriers
//      - Instantiates pass templates (PER_CAMERA, PER_LIGHT expansion)
//      - Topological sort (Kahn's algorithm)
//      - Automatic barrier inference from resource access patterns
//
// EXECUTE PHASE:
//   6. graph_execute() - Render frame with automatic synchronization
//      - Emits barriers before each pass
//      - Calls pass execute callbacks with resolved resources
//
// Example usage:
//
//   g: Graph
//   graph_init(&g)
//
//   // Setup phase (once)
//   graph_register_resource(&g, depth_desc)
//
//   // Setup phase (each frame)
//   templates := []PassTemplate{
//     graph_make_pass_template(GEOMETRY_PASS, active_cameras, geometry_execute),
//   }
//
//   // Compile phase
//   if graph_compile(&g, templates, &exec_ctx) != .SUCCESS {
//       log.error("Graph compilation failed")
//   }
//
//   // Execute phase
//   graph_execute(&g, cmd, frame_index)

import "core:log"
import "core:slice"

// Constants for pre-resolved handle arrays
FRAMES_IN_FLIGHT :: 2
MAX_CAMERAS :: 64
MAX_LIGHTS :: 256

// Array sizes computed directly from ResourceIndex ranges.
MAX_GLOBAL_RESOURCES :: u32(ResourceIndex._PER_FRAME_START)
MAX_PER_FRAME_RESOURCES ::
  u32(ResourceIndex._PER_CAMERA_START) - u32(ResourceIndex._PER_FRAME_START)
MAX_PER_CAMERA_RESOURCES ::
  u32(ResourceIndex._PER_LIGHT_START) - u32(ResourceIndex._PER_CAMERA_START)
MAX_PER_LIGHT_RESOURCES ::
  u32(ResourceIndex._DYNAMIC_START) - u32(ResourceIndex._PER_LIGHT_START)

// Result type for graph operations
Result :: enum {
  SUCCESS,
  ERROR_CYCLIC_DEPENDENCY,
  ERROR_MISSING_RESOURCE,
  ERROR_INVALID_PASS,
}

ResourceLifetime :: struct {
  first_use_step: int,
  last_use_step:  int,
}

TransientResourceInfo :: struct {
  resource_key: ResourceKey,
  desc:         ResourceDescriptor,
  lifetime:     ResourceLifetime,
}

// Reserved for transient allocation/aliasing implementation.
TransientResourcePool :: struct {
  transient_resources: [dynamic]TransientResourceInfo,
}

// Core Graph type
// Graph is PURE RUNTIME STATE - templates are passed as compile() parameters, not stored
Graph :: struct {
  // Resource registry keyed by typed resource identity.
  resources:                map[ResourceKey]ResourceDescriptor,

  // Compiled pass instances (after template instantiation)
  passes:                   [dynamic]PassInstance,

  // Compiled execution plan
  execution_order:          [dynamic]PassId,
  barriers:                 map[PassId][dynamic]Barrier,
  resource_lifetimes:       map[ResourceKey]ResourceLifetime,

  // Pre-resolved runtime resources for O(1) execute-time access.
  global_resources:         [MAX_GLOBAL_RESOURCES]Resource,
  global_resource_valid:    [MAX_GLOBAL_RESOURCES]bool,
  per_frame_resources:      [FRAMES_IN_FLIGHT][MAX_PER_FRAME_RESOURCES]Resource,
  per_frame_resource_valid: [FRAMES_IN_FLIGHT][MAX_PER_FRAME_RESOURCES]bool,
  camera_resources:         [FRAMES_IN_FLIGHT][MAX_CAMERAS][MAX_PER_CAMERA_RESOURCES]Resource,
  camera_resource_valid:    [FRAMES_IN_FLIGHT][MAX_CAMERAS][MAX_PER_CAMERA_RESOURCES]bool,
  light_resources:          [FRAMES_IN_FLIGHT][MAX_LIGHTS][MAX_PER_LIGHT_RESOURCES]Resource,
  light_resource_valid:     [FRAMES_IN_FLIGHT][MAX_LIGHTS][MAX_PER_LIGHT_RESOURCES]bool,

  // Internal seam for transient allocation/aliasing.
  transient_pool:           TransientResourcePool,

  // Compile-time execution context snapshot used by execute callbacks.
  exec_ctx:                 GraphExecutionContext,
  has_exec_ctx:             bool,
}

@(private)
_transient_pool_init :: proc(pool: ^TransientResourcePool) {
  pool.transient_resources = make([dynamic]TransientResourceInfo)
}

@(private)
_transient_pool_destroy :: proc(pool: ^TransientResourcePool) {
  delete(pool.transient_resources)
}

@(private)
_transient_pool_begin_frame :: proc(pool: ^TransientResourcePool) {
  clear(&pool.transient_resources)
}

@(private)
_transient_pool_compile :: proc(
  pool: ^TransientResourcePool,
  g: ^Graph,
) -> Result {
  clear(&pool.transient_resources)
  for res_key, desc in g.resources {
    if !desc.is_transient do continue
    lifetime, has_lifetime := g.resource_lifetimes[res_key]
    if !has_lifetime do continue
    append(
      &pool.transient_resources,
      TransientResourceInfo {
        resource_key = res_key,
        desc = desc,
        lifetime = lifetime,
      },
    )
  }
  slice.sort_by(
    pool.transient_resources[:],
    proc(a, b: TransientResourceInfo) -> bool {
      if a.lifetime.first_use_step != b.lifetime.first_use_step {
        return a.lifetime.first_use_step < b.lifetime.first_use_step
      }
      if a.lifetime.last_use_step != b.lifetime.last_use_step {
        return a.lifetime.last_use_step > b.lifetime.last_use_step
      }
      if a.resource_key.index != b.resource_key.index {
        return a.resource_key.index < b.resource_key.index
      }
      return a.resource_key.scope_index < b.resource_key.scope_index
    },
  )
  if len(pool.transient_resources) > 0 {
    log.infof(
      "Transient compile prepared %d resources",
      len(pool.transient_resources),
    )
  }
  return .SUCCESS
}

// ============================================================================
// PUBLIC API - SETUP PHASE
// ============================================================================

// Initialize empty graph
graph_init :: proc(g: ^Graph) {
  g.resources = make(map[ResourceKey]ResourceDescriptor)
  g.passes = make([dynamic]PassInstance)
  g.execution_order = make([dynamic]PassId)
  g.barriers = make(map[PassId][dynamic]Barrier)
  g.resource_lifetimes = make(map[ResourceKey]ResourceLifetime)
  _transient_pool_init(&g.transient_pool)
}

// Cleanup graph resources
graph_destroy :: proc(g: ^Graph) {
  _clear_compiled_state(g)

  delete(g.resources)
  delete(g.passes)

  delete(g.execution_order)
  delete(g.barriers)
  delete(g.resource_lifetimes)
  _transient_pool_destroy(&g.transient_pool)
}

// Reset graph for next frame (clears compiled state only)
// Templates are now passed as parameters to graph_compile(), not stored in Graph
graph_reset :: proc(g: ^Graph) {
  _clear_compiled_state(g)
  _transient_pool_begin_frame(&g.transient_pool)
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_clear_compiled_state :: proc(g: ^Graph) {
  for &pass in g.passes {
    delete(pass.inputs)
    delete(pass.outputs)
  }
  clear(&g.passes)

  clear(&g.execution_order)
  for _, barriers in g.barriers {
    delete(barriers)
  }
  clear(&g.barriers)

  clear(&g.resource_lifetimes)
  _clear_resolved_resources(g)
  g.exec_ctx = {}
  g.has_exec_ctx = false
}

// Register resource in graph
graph_register_resource :: proc(g: ^Graph, desc: ResourceDescriptor) {
  resource_key := resource_ref_key(desc.ref)
  expected_type := resource_ref_type(desc.ref)
  if desc.type != expected_type {
    log.errorf(
      "Resource type mismatch for index=%v scope=%d: declared %v, expected %v",
      desc.ref.index,
      resource_key.scope_index,
      desc.type,
      expected_type,
    )
    return
  }

  if resource_key in g.resources {
    log.warnf(
      "Resource already registered for index=%v scope=%d",
      resource_key.index,
      resource_key.scope_index,
    )
    return
  }

  g.resources[resource_key] = desc
}

// Register pass template (declarative, with inputs/outputs)
// Combines declarative structure (inputs/outputs) with runtime behavior (execute callback)
// Returns a fully-populated PassTemplate ready for graph_compile()
graph_make_pass_template :: proc(
  decl: PassTemplate, // Declarative template with inputs/outputs
  instance_indices: []u32, // Active camera/light indices
  execute: PassExecuteProc, // Execute callback (runtime)
) -> PassTemplate {
  template := decl
  template.instance_indices = instance_indices
  template.execute = execute
  return template
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_get_resource_descriptor :: proc(
  g: ^Graph,
  res_key: ResourceKey,
) -> (
  ResourceDescriptor,
  bool,
) {
  desc, ok := g.resources[res_key]
  return desc, ok
}

// ============================================================================
// PUBLIC API - COMPILE PHASE
// ============================================================================

// Compile graph: instantiate passes, build execution order, compute barriers
// Takes templates as parameter (NOT stored in Graph)
graph_compile :: proc(
  g: ^Graph,
  templates: []PassTemplate,
  exec_ctx: ^GraphExecutionContext = nil,
) -> Result {
  _clear_compiled_state(g)
  if exec_ctx != nil {
    g.exec_ctx = exec_ctx^
    g.has_exec_ctx = true
  }
  if err := _instantiate_passes(g, templates); err != .SUCCESS do return err
  if err := _validate_passes(g); err != .SUCCESS do return err
  if len(g.passes) > 0 &&
     (exec_ctx == nil || exec_ctx.resolve_resource_index == nil) {
    log.error(
      "GraphExecutionContext.resolve_resource_index is required for index-only graph resolution",
    )
    return .ERROR_MISSING_RESOURCE
  }
  if err := _build_execution_order(g); err != .SUCCESS do return err
  _compute_resource_lifetimes(g)
  if err := _transient_pool_compile(&g.transient_pool, g); err != .SUCCESS do return err

  // Pre-resolve all resources referenced by compiled pass instances.
  // This validates ResourceIndex-to-runtime resolver wiring ahead of execute()
  // and stores handles in graph-owned arrays for O(1) runtime access.
  if err := _pre_resolve_resources(g, exec_ctx); err != .SUCCESS do return err

  if err := _compute_barriers(g); err != .SUCCESS do return err
  return .SUCCESS
}

@(private)
_resolve_resource_from_exec_ctx :: proc(
  exec_ctx: ^GraphExecutionContext,
  idx: ResourceIndex,
  frame_index, scope_index: u32,
) -> (
  Resource,
  bool,
) {
  if exec_ctx == nil || exec_ctx.resolve_resource_index == nil {
    return {}, false
  }

  resolved_scope := scope_index
  scope := resource_scope_for_index(idx)
  if scope == .GLOBAL || scope == .PER_FRAME {
    resolved_scope = 0
  }

  return exec_ctx.resolve_resource_index(
    exec_ctx.render_manager,
    idx,
    frame_index,
    resolved_scope,
  )
}

@(private)
_clear_resolved_resources :: proc(g: ^Graph) {
  g.global_resources = {}
  g.global_resource_valid = {}

  g.per_frame_resources = {}
  g.per_frame_resource_valid = {}

  g.camera_resources = {}
  g.camera_resource_valid = {}

  g.light_resources = {}
  g.light_resource_valid = {}
}

@(private)
_set_resolved_resource :: proc(
  g: ^Graph,
  idx: ResourceIndex,
  frame_index, scope_index: u32,
  handle: Resource,
) -> bool {
  scope := resource_scope_for_index(idx)
  offset := u32(resource_index_offset(idx))
  switch scope {
  case .GLOBAL:
    if offset >= MAX_GLOBAL_RESOURCES do return false
    g.global_resources[offset] = handle
    g.global_resource_valid[offset] = true
    return true
  case .PER_FRAME:
    if frame_index >= FRAMES_IN_FLIGHT || offset >= MAX_PER_FRAME_RESOURCES do return false
    g.per_frame_resources[frame_index][offset] = handle
    g.per_frame_resource_valid[frame_index][offset] = true
    return true
  case .PER_CAMERA:
    if frame_index >= FRAMES_IN_FLIGHT || scope_index >= MAX_CAMERAS || offset >= MAX_PER_CAMERA_RESOURCES do return false
    g.camera_resources[frame_index][scope_index][offset] = handle
    g.camera_resource_valid[frame_index][scope_index][offset] = true
    return true
  case .PER_LIGHT:
    if frame_index >= FRAMES_IN_FLIGHT || scope_index >= MAX_LIGHTS || offset >= MAX_PER_LIGHT_RESOURCES do return false
    g.light_resources[frame_index][scope_index][offset] = handle
    g.light_resource_valid[frame_index][scope_index][offset] = true
    return true
  }
  return false
}

graph_get_resolved_resource :: proc(
  g: ^Graph,
  idx: ResourceIndex,
  frame_index, scope_index: u32,
) -> (
  Resource,
  bool,
) {
  if g == nil do return {}, false

  scope := resource_scope_for_index(idx)
  offset := u32(resource_index_offset(idx))
  resolved_scope := scope_index
  if scope == .GLOBAL || scope == .PER_FRAME {
    resolved_scope = 0
  }

  switch scope {
  case .GLOBAL:
    if offset >= MAX_GLOBAL_RESOURCES do return {}, false
    if !g.global_resource_valid[offset] do return {}, false
    return g.global_resources[offset], true
  case .PER_FRAME:
    if frame_index >= FRAMES_IN_FLIGHT || offset >= MAX_PER_FRAME_RESOURCES do return {}, false
    if !g.per_frame_resource_valid[frame_index][offset] do return {}, false
    return g.per_frame_resources[frame_index][offset], true
  case .PER_CAMERA:
    if frame_index >= FRAMES_IN_FLIGHT || resolved_scope >= MAX_CAMERAS || offset >= MAX_PER_CAMERA_RESOURCES do return {}, false
    if !g.camera_resource_valid[frame_index][resolved_scope][offset] do return {}, false
    return g.camera_resources[frame_index][resolved_scope][offset], true
  case .PER_LIGHT:
    if frame_index >= FRAMES_IN_FLIGHT || resolved_scope >= MAX_LIGHTS || offset >= MAX_PER_LIGHT_RESOURCES do return {}, false
    if !g.light_resource_valid[frame_index][resolved_scope][offset] do return {}, false
    return g.light_resources[frame_index][resolved_scope][offset], true
  }

  return {}, false
}

@(private)
_pre_resolve_resources :: proc(
  g: ^Graph,
  exec_ctx: ^GraphExecutionContext,
) -> Result {
  _clear_resolved_resources(g)

  if len(g.passes) == 0 {
    return .SUCCESS
  }

  if exec_ctx == nil || exec_ctx.resolve_resource_index == nil {
    log.error(
      "GraphExecutionContext.resolve_resource_index is required for pre-resolving resources",
    )
    return .ERROR_MISSING_RESOURCE
  }

  used_resource_keys := make(map[ResourceKey]bool)
  defer delete(used_resource_keys)

  for pass in g.passes {
    for input_key in pass.inputs {
      used_resource_keys[input_key] = true
    }
    for output_key in pass.outputs {
      used_resource_keys[output_key] = true
    }
  }

  resolved_count := 0
  unresolved_count := 0
  for res_key in used_resource_keys {
    _, has_desc := _get_resource_descriptor(g, res_key)
    if !has_desc do continue
    scope := resource_scope_for_index(res_key.index)
    scope_index := res_key.scope_index
    if scope == .GLOBAL || scope == .PER_FRAME {
      scope_index = 0
    }

    frame_start, frame_end := 0, FRAMES_IN_FLIGHT
    if scope == .GLOBAL {
      frame_end = 1
    }

    for frame_idx in frame_start ..< frame_end {
      handle, ok := _resolve_resource_from_exec_ctx(
        exec_ctx,
        res_key.index,
        u32(frame_idx),
        scope_index,
      )
      if !ok {
        // Some resources are intentionally optional for a frame/scope
        // (e.g. fixed shadow-map dependencies for inactive light slots).
        unresolved_count += 1
        continue
      }

      if !_set_resolved_resource(
        g,
        res_key.index,
        u32(frame_idx),
        scope_index,
        handle,
      ) {
        log.errorf(
          "Resolved resource index=%v scope=%d frame=%d is out of graph bounds",
          res_key.index,
          scope_index,
          frame_idx,
        )
        return .ERROR_MISSING_RESOURCE
      }
      resolved_count += 1
    }
  }

  if resolved_count > 0 {
    log.infof("Pre-resolved %d resource handles", resolved_count)
  }
  if unresolved_count > 0 {
    log.infof(
      "Skipped %d unresolved optional resource handles",
      unresolved_count,
    )
  }
  return .SUCCESS
}

// ============================================================================
// PRIVATE COMPILATION STAGES
// ============================================================================

@(private)
_instantiate_passes :: proc(g: ^Graph, templates: []PassTemplate) -> Result {
  for template in templates {
    // Make mutable copy for iteration
    temp := template
    switch temp.scope {
    case .GLOBAL:
      instance := _create_pass_instance(g, &temp, 0)
      append(&g.passes, instance)

    case .PER_CAMERA:
      for cam_index in temp.instance_indices {
        instance := _create_pass_instance(g, &temp, cam_index)
        append(&g.passes, instance)
      }

    case .PER_LIGHT:
      for light_index in temp.instance_indices {
        instance := _create_pass_instance(g, &temp, light_index)
        append(&g.passes, instance)
      }
    }
  }

  log.infof(
    "Instantiated %d passes from %d templates",
    len(g.passes),
    len(templates),
  )
  return .SUCCESS
}

@(private)
_validate_resource_ref :: proc(
  g: ^Graph,
  template_id: PassTemplateId,
  resource_ref: ResourceRef,
) -> bool {
  resource_key := resource_ref_key(resource_ref)
  desc, has_desc := _get_resource_descriptor(g, resource_key)
  if !has_desc {
    log.errorf(
      "Pass template %d references unregistered resource index=%v scope=%d",
      u32(template_id),
      resource_key.index,
      resource_key.scope_index,
    )
    return false
  }
  if !resource_ref_matches(desc.ref, resource_ref) {
    log.errorf(
      "Pass template %d references mismatched typed resource index=%v scope=%d",
      u32(template_id),
      resource_key.index,
      resource_key.scope_index,
    )
    return false
  }
  return true
}

@(private)
_create_pass_instance :: proc(
  g: ^Graph,
  template: ^PassTemplate,
  scope_index: u32,
) -> PassInstance {
  instance := PassInstance {
    template_id = template.id,
    scope_index = scope_index,
    queue       = template.queue,
    execute     = template.execute,
    inputs      = make([dynamic]ResourceKey),
    outputs     = make([dynamic]ResourceKey),
    is_valid    = true,
  }

  // Declarative path: instantiate typed resource templates.
  for input_template in template.inputs {
    resource_ref := resource_ref_from_template(input_template, scope_index)
    if !_validate_resource_ref(g, template.id, resource_ref) {
      instance.is_valid = false
    }
    append(&instance.inputs, resource_ref_key(resource_ref))
  }
  for output_template in template.outputs {
    resource_ref := resource_ref_from_template(output_template, scope_index)
    if !_validate_resource_ref(g, template.id, resource_ref) {
      instance.is_valid = false
    }
    append(&instance.outputs, resource_ref_key(resource_ref))
  }

  return instance
}

@(private)
_validate_passes :: proc(g: ^Graph) -> Result {
  for pass in g.passes {
    if pass.is_valid {
      continue
    }
    log.errorf(
      "Invalid pass template %d (scope index: %d): missing graph resources in setup",
      u32(pass.template_id),
      pass.scope_index,
    )
    return .ERROR_MISSING_RESOURCE
  }
  return .SUCCESS
}

@(private)
_compute_resource_lifetimes :: proc(g: ^Graph) {
  clear(&g.resource_lifetimes)
  for pass_id, step_idx in g.execution_order {
    pass := &g.passes[pass_id]
    for res_key in pass.inputs {
      _record_resource_lifetime(g, res_key, step_idx)
    }
    for res_key in pass.outputs {
      _record_resource_lifetime(g, res_key, step_idx)
    }
  }
}

@(private)
_record_resource_lifetime :: proc(
  g: ^Graph,
  res_key: ResourceKey,
  step_idx: int,
) {
  if lifetime, ok := g.resource_lifetimes[res_key]; ok {
    if step_idx < lifetime.first_use_step {
      lifetime.first_use_step = step_idx
    }
    if step_idx > lifetime.last_use_step {
      lifetime.last_use_step = step_idx
    }
    g.resource_lifetimes[res_key] = lifetime
    return
  }
  g.resource_lifetimes[res_key] = ResourceLifetime {
    first_use_step = step_idx,
    last_use_step  = step_idx,
  }
}

@(private)
_pass_reads_resource :: proc(
  pass: ^PassInstance,
  res_key: ResourceKey,
) -> bool {
  for input_res in pass.inputs {
    if input_res == res_key {
      return true
    }
  }
  return false
}

@(private)
_pass_writes_resource :: proc(
  pass: ^PassInstance,
  res_key: ResourceKey,
) -> bool {
  for output_res in pass.outputs {
    if output_res == res_key {
      return true
    }
  }
  return false
}

@(private)
_build_execution_order :: proc(g: ^Graph) -> Result {
  pass_count := len(g.passes)
  in_degree := make([]int, pass_count)
  defer delete(in_degree)
  adj_list := make([][dynamic]PassId, pass_count)
  defer {
    for &neighbors in adj_list {
      delete(neighbors)
    }
    delete(adj_list)
  }

  add_edge :: proc(
    adj: ^[][dynamic]PassId,
    in_degree: ^[]int,
    src_idx, dst_idx: int,
  ) {
    if src_idx == dst_idx do return
    dst := PassId(dst_idx)
    for existing_dst in adj[src_idx] {
      if existing_dst == dst {
        return
      }
    }
    append(&adj[src_idx], dst)
    in_degree[dst_idx] += 1
  }

  resource_keys := make([dynamic]ResourceKey, 0, len(g.resources))
  defer delete(resource_keys)
  for res_key in g.resources {
    append(&resource_keys, res_key)
  }
  slice.sort_by(resource_keys[:], proc(a, b: ResourceKey) -> bool {
    if a.index != b.index {
      return a.index < b.index
    }
    return a.scope_index < b.scope_index
  })

  // Build forward dependencies per resource by declaration order.
  // This handles read-write (RMW) resources without generating backward edges.
  for res_key in resource_keys {
    last_writer_idx := -1
    readers_since_last_write := make([dynamic]int)

    for pass_idx in 0 ..< pass_count {
      pass := &g.passes[pass_idx]
      reads := _pass_reads_resource(pass, res_key)
      writes := _pass_writes_resource(pass, res_key)
      if !reads && !writes do continue

      if reads {
        if last_writer_idx >= 0 {
          add_edge(&adj_list, &in_degree, last_writer_idx, pass_idx)
        }
        append(&readers_since_last_write, pass_idx)
      }

      if writes {
        if last_writer_idx >= 0 {
          add_edge(&adj_list, &in_degree, last_writer_idx, pass_idx)
        }
        for reader_idx in readers_since_last_write {
          add_edge(&adj_list, &in_degree, reader_idx, pass_idx)
        }
        last_writer_idx = pass_idx
        clear(&readers_since_last_write)
      }
    }

    delete(readers_since_last_write)
  }

  // Kahn's topological sort
  queue := make([dynamic]PassId)
  defer delete(queue)

  for pass_idx in 0 ..< pass_count {
    if in_degree[pass_idx] == 0 {
      append(&queue, PassId(pass_idx))
    }
  }

  clear(&g.execution_order)
  queue_head := 0
  for queue_head < len(queue) {
    current := queue[queue_head]
    queue_head += 1

    append(&g.execution_order, current)

    for neighbor in adj_list[int(current)] {
      neighbor_idx := int(neighbor)
      in_degree[neighbor_idx] -= 1
      if in_degree[neighbor_idx] == 0 {
        append(&queue, neighbor)
      }
    }
  }

  // Detect cycles
  if len(g.execution_order) != len(g.passes) {
    log.errorf(
      "Cyclic dependency detected! Expected %d passes, got %d in execution order",
      len(g.passes),
      len(g.execution_order),
    )
    return .ERROR_CYCLIC_DEPENDENCY
  }

  log.infof("Built execution order for %d passes", len(g.execution_order))
  return .SUCCESS
}

// Barrier and compute_barriers are defined in barrier.odin
