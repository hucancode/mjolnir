package render_graph

import "core:fmt"
import "core:slice"
import vk "vendor:vulkan"

// ============================================================================
// Main Compilation Entry Point
// ============================================================================

compile :: proc(
  pass_decls: []PassDecl,
  ctx: CompileContext,
  loc := #caller_location,
) -> (
  graph: Graph,
  err: CompileError,
) {
  // Initialize graph
  init(&graph, ctx.frames_in_flight)

  // Store handle mappings
  graph.camera_handles = slice.clone(ctx.camera_handles)
  graph.light_handles = slice.clone(ctx.light_handles)

  // Step 1: Instantiate passes based on scope
  instances, resources_per_instance := instantiate_passes(pass_decls, ctx) or_return
  defer delete(resources_per_instance)

  // Step 2: Expand declarative ResourceSpec slices to collect resource declarations
  // and per-instance reads/writes.
  all_resources: [dynamic]ResourceDecl
  defer delete(all_resources)

  // Tracks the current write-version for each resource, incremented on each write.
  // Version numbers let build_dependency_edges resolve "which pass wrote what I read"
  // as a direct O(1) lookup instead of a nearest-predecessor search.
  resource_versions := make(map[string]u32)
  defer delete(resource_versions)

  // Global set of already-registered resource names (prevents duplicate ResourceDecls).
  resource_name_set := make(map[string]bool)
  defer delete(resource_name_set)

  // Canonical name table: maps scoped-name-content → persistent string owned by
  // all_resources (so desc==nil accesses can borrow instead of allocating).
  canonical_names := make(map[string]string)
  defer delete(canonical_names)

  for &instance, i in instances {
    expand_resource_specs(
      &instance,
      resources_per_instance[i],
      ctx,
      &all_resources,
      &resource_name_set,
      &canonical_names,
      &resource_versions,
    )
  }

  // Step 3: Create resource instances
  resource_map := make(map[string]ResourceInstanceId, len(all_resources))
  defer delete(resource_map)

  for res_decl in all_resources {
    // Check if resource already exists (multiple passes can create same resource)
    if _, exists := resource_map[res_decl.name]; exists {
      // Free the duplicate heap-allocated name (non-GLOBAL names are fmt.aprintf'd)
      if res_decl.scope != .GLOBAL do delete(res_decl.name)
      continue
    }

    data: union {
      ResourceTexture,
      ResourceTextureCube,
      ResourceBuffer,
    }
    switch d in res_decl.desc {
    case TextureDesc:
      data = ResourceTexture {
        width         = d.width,
        height        = d.height,
        format        = d.format,
        usage         = d.usage,
        aspect        = d.aspect,
        double_buffer = d.double_buffer,
      }
    case TextureCubeDesc:
      data = ResourceTextureCube {
        width  = d.width,
        format = d.format,
        usage  = d.usage,
        aspect = d.aspect,
      }
    case BufferDesc:
      data = ResourceBuffer {
        size  = d.size,
        usage = d.usage,
      }
    }
    res_instance := ResourceInstance {
      name         = res_decl.name,
      scope        = res_decl.scope,
      instance_idx = res_decl.instance_idx,
      is_external  = res_decl.is_external,
      data         = data,
    }

    id := add_resource_instance(&graph, res_instance)
    resource_map[res_decl.name] = id
  }

  // Step 4: Add pass instances to graph
  for instance in instances {
    add_pass_instance(&graph, instance)
  }

  // Step 5: Validate graph
  validate_graph(&graph, resource_map) or_return

  // Step 6: Build dependency edges
  edges := build_dependency_edges(&graph, resource_map)
  defer {
    for _, edge_list in edges {
      delete(edge_list)
    }
    delete(edges)
  }

  // Step 7: Eliminate dead passes
  live_passes := eliminate_dead_passes(&graph, edges)
  defer delete(live_passes)

  when ODIN_DEBUG {
    log.info("=== DEAD PASS ELIMINATION ===")
    for &pass, idx in graph.pass_instances {
      log.infof("[%s] %s", live_passes[idx] ? "LIVE" : "DEAD", pass.name)
    }
    log.info("=============================\n")
  }

  // Step 8: Topological sort
  sorted := topological_sort(&graph, edges, live_passes) or_return
  defer delete(sorted)

  // Step 9: Set execution order
  set_execution_order(&graph, sorted[:])

  // Step 10: Assign resource aliases.
  // Two virtual resources with non-overlapping lifetimes and compatible Vulkan
  // descriptors are allowed to share the same underlying GPU allocation.
  // Must run after sorted_passes is set (lifetimes are computed from it).
  assign_resource_aliases(&graph)

  return graph, .NONE
}

// ============================================================================
// Pass Instantiation
// ============================================================================

instantiate_passes :: proc(
  pass_decls: []PassDecl,
  ctx: CompileContext,
  loc := #caller_location,
) -> (
  instances: [dynamic]PassInstance,
  resources_per_instance: [dynamic][]ResourceSpec,
  err: CompileError,
) {
  instances = make([dynamic]PassInstance)
  resources_per_instance = make([dynamic][]ResourceSpec)

  _append :: proc(
    instances: ^[dynamic]PassInstance,
    resources: ^[dynamic][]ResourceSpec,
    inst: PassInstance,
    res: []ResourceSpec,
  ) {
    append(instances, inst)
    append(resources, res)
  }

  for decl in pass_decls {
    switch decl.scope {
    case .GLOBAL:
      _append(
        &instances,
        &resources_per_instance,
        PassInstance{
          name    = decl.name,
          scope   = decl.scope,
          instance = 0,
          queue   = decl.queue,
          execute = decl.execute,
        },
        decl.resources,
      )

    case .PER_CAMERA:
      for cam_idx in 0 ..< len(ctx.camera_handles) {
        _append(
          &instances,
          &resources_per_instance,
          PassInstance{
            name     = fmt.aprintf("%s_cam_%d", decl.name, cam_idx),
            scope    = decl.scope,
            instance = u32(cam_idx),
            queue    = decl.queue,
            execute  = decl.execute,
          },
          decl.resources,
        )
      }

    case .PER_POINT_LIGHT:
      for light_idx in 0 ..< len(ctx.light_kinds) {
        if ctx.light_kinds[light_idx] != .POINT do continue
        _append(
          &instances,
          &resources_per_instance,
          PassInstance{
            name     = fmt.aprintf("%s_light_%d", decl.name, light_idx),
            scope    = decl.scope,
            instance = u32(light_idx),
            queue    = decl.queue,
            execute  = decl.execute,
          },
          decl.resources,
        )
      }

    case .PER_SPOT_LIGHT:
      for light_idx in 0 ..< len(ctx.light_kinds) {
        if ctx.light_kinds[light_idx] != .SPOT do continue
        _append(
          &instances,
          &resources_per_instance,
          PassInstance{
            name     = fmt.aprintf("%s_light_%d", decl.name, light_idx),
            scope    = decl.scope,
            instance = u32(light_idx),
            queue    = decl.queue,
            execute  = decl.execute,
          },
          decl.resources,
        )
      }

    case .PER_DIRECTIONAL_LIGHT:
      for light_idx in 0 ..< len(ctx.light_kinds) {
        if ctx.light_kinds[light_idx] != .DIRECTIONAL do continue
        _append(
          &instances,
          &resources_per_instance,
          PassInstance{
            name     = fmt.aprintf("%s_light_%d", decl.name, light_idx),
            scope    = decl.scope,
            instance = u32(light_idx),
            queue    = decl.queue,
            execute  = decl.execute,
          },
          decl.resources,
        )
      }
    }
  }

  return instances, resources_per_instance, .NONE
}

// ============================================================================
// Declarative Resource Spec Expansion
// ============================================================================

// expand_resource_specs processes the []ResourceSpec for one pass instance,
// creating ResourceDecls for new resources and recording reads/writes.
@(private = "package")
expand_resource_specs :: proc(
  instance: ^PassInstance,
  specs: []ResourceSpec,
  ctx: CompileContext,
  all_resources: ^[dynamic]ResourceDecl,
  resource_name_set: ^map[string]bool,
  canonical_names: ^map[string]string,
  resource_versions: ^map[string]u32,
) {
  reads := make([dynamic]ResourceAccess)
  writes := make([dynamic]ResourceAccess)

  for spec in specs {
    scope_ref := spec.scope_ref
    if scope_ref == nil {
      scope_ref = SameScope{}
    }
    switch ref in scope_ref {
    case SameScope:
      _expand_single(
        spec,
        instance.scope,
        instance.instance,
        instance.instance,
        ctx,
        all_resources,
        resource_name_set,
        canonical_names,
        &reads,
        &writes,
      )
    case CrossScope:
      _expand_single(
        spec,
        ref.scope,
        ref.instance,
        instance.instance,
        ctx,
        all_resources,
        resource_name_set,
        canonical_names,
        &reads,
        &writes,
      )
    case AllOfScope:
      switch ref.scope {
      case .GLOBAL:
        _expand_single(spec, .GLOBAL, 0, instance.instance, ctx, all_resources, resource_name_set, canonical_names, &reads, &writes)
      case .PER_CAMERA:
        for cam_idx in 0 ..< len(ctx.camera_handles) {
          _expand_single(spec, .PER_CAMERA, u32(cam_idx), instance.instance, ctx, all_resources, resource_name_set, canonical_names, &reads, &writes)
        }
      case .PER_POINT_LIGHT:
        for light_idx in 0 ..< len(ctx.light_kinds) {
          if ctx.light_kinds[light_idx] == .POINT {
            _expand_single(spec, .PER_POINT_LIGHT, u32(light_idx), instance.instance, ctx, all_resources, resource_name_set, canonical_names, &reads, &writes)
          }
        }
      case .PER_SPOT_LIGHT:
        for light_idx in 0 ..< len(ctx.light_kinds) {
          if ctx.light_kinds[light_idx] == .SPOT {
            _expand_single(spec, .PER_SPOT_LIGHT, u32(light_idx), instance.instance, ctx, all_resources, resource_name_set, canonical_names, &reads, &writes)
          }
        }
      case .PER_DIRECTIONAL_LIGHT:
        for light_idx in 0 ..< len(ctx.light_kinds) {
          if ctx.light_kinds[light_idx] == .DIRECTIONAL {
            _expand_single(spec, .PER_DIRECTIONAL_LIGHT, u32(light_idx), instance.instance, ctx, all_resources, resource_name_set, canonical_names, &reads, &writes)
          }
        }
      }
    }
  }

  // Assign versions: reads capture current version, writes mint next.
  // Must process reads before writes so a READ_WRITE pass reads version N then produces N+1.
  for &read in reads {
    if read.frame_offset == .CURRENT {
      read.version = resource_versions[read.resource_name]
    }
  }
  for &write in writes {
    if write.frame_offset == .CURRENT {
      resource_versions[write.resource_name] += 1
      write.version = resource_versions[write.resource_name]
    }
  }

  instance.reads = reads
  instance.writes = writes
}

// _expand_single resolves one ResourceSpec against a concrete (scope, instance_idx) target.
// `pass_instance_idx` is the pass's own instance index, used for CameraExtent resolution.
@(private = "package")
_expand_single :: proc(
  spec: ResourceSpec,
  scope: PassScope,
  instance_idx: u32,
  pass_instance_idx: u32,
  ctx: CompileContext,
  all_resources: ^[dynamic]ResourceDecl,
  resource_name_set: ^map[string]bool,
  canonical_names: ^map[string]string,
  reads: ^[dynamic]ResourceAccess,
  writes: ^[dynamic]ResourceAccess,
) {
  scoped_name := scope_resource_name(spec.name, scope, instance_idx)

  canonical: string

  if spec.desc != nil {
    if !resource_name_set[scoped_name] {
      // First time seeing this resource: register it.
      resource_name_set[scoped_name] = true
      canonical_names[scoped_name] = scoped_name
      canonical = scoped_name

      desc_concrete: union {
        TextureDesc,
        TextureCubeDesc,
        BufferDesc,
      }
      switch d in spec.desc {
      case TextureDescSpec:
        w: u32
        switch sw in d.width {
        case u32:
          w = sw
        case CameraExtent:
          w = 1920
          if int(pass_instance_idx) < len(ctx.camera_extents) {
            w = ctx.camera_extents[pass_instance_idx].width
          }
        }
        h: u32
        switch sh in d.height {
        case u32:
          h = sh
        case CameraExtent:
          h = 1080
          if int(pass_instance_idx) < len(ctx.camera_extents) {
            h = ctx.camera_extents[pass_instance_idx].height
          }
        }
        fmt_val: vk.Format
        switch sf in d.format {
        case vk.Format:
          fmt_val = sf
        case SwapchainFormat:
          fmt_val = ctx.swapchain_format
        }
        double_buf: bool
        switch d.double_buffer {
        case .NO:
          double_buf = false
        case .YES:
          double_buf = true
        case .WHEN_SECONDARY:
          double_buf = pass_instance_idx > 0
        }
        desc_concrete = TextureDesc{
          width         = w,
          height        = h,
          format        = fmt_val,
          usage         = d.usage,
          aspect        = d.aspect,
          double_buffer = double_buf,
        }
      case TextureCubeDescSpec:
        desc_concrete = TextureCubeDesc{
          width  = d.width,
          format = d.format,
          usage  = d.usage,
          aspect = d.aspect,
        }
      case BufferDescSpec:
        desc_concrete = BufferDesc{
          size  = d.size,
          usage = d.usage,
        }
      }
      append(
        all_resources,
        ResourceDecl{
          name         = scoped_name,
          desc         = desc_concrete,
          scope        = scope,
          instance_idx = instance_idx,
          is_external  = spec.is_external,
        },
      )
    } else {
      // Resource already registered: borrow canonical name, free duplicate allocation.
      canonical = canonical_names[scoped_name]
      if scope != .GLOBAL do delete(scoped_name)
    }
  } else {
    // No desc: referencing an existing resource.
    // Borrow the canonical name if registered; otherwise use scoped_name as-is
    // (validate_graph will catch the dangling reference).
    if c, ok := canonical_names[scoped_name]; ok {
      canonical = c
      if scope != .GLOBAL do delete(scoped_name)
    } else {
      // Resource not yet registered (will be caught by validate_graph).
      canonical = scoped_name
    }
  }

  // Register access.
  acc := ResourceAccess{
    resource_name = canonical,
    frame_offset  = spec.frame_offset,
    access_mode   = spec.access,
  }
  if spec.access != .WRITE do append(reads, acc)
  if spec.access != .READ do append(writes, acc)
}

// ============================================================================
// Graph Validation
// ============================================================================

validate_graph :: proc(
  graph: ^Graph,
  resource_map: map[string]ResourceInstanceId,
  loc := #caller_location,
) -> CompileError {
  // Build set of all written resources (with frame offsets)
  written_resources := make(map[string]bool)
  defer delete(written_resources)

  for &pass in graph.pass_instances {
    for write in pass.writes {
      written_resources[write.resource_name] = true
    }
  }

  // Check for dangling reads (read without corresponding write)
  for &pass in graph.pass_instances {
    for read in pass.reads {
      // Check if resource exists
      if _, exists := resource_map[read.resource_name]; !exists {
        fmt.eprintf(
          "ERROR: Pass '%s' reads non-existent resource '%s'\n",
          pass.name,
          read.resource_name,
        )
        return .DANGLING_READ
      }

      // For CURRENT/PREV reads, ensure someone writes it
      if read.frame_offset == .CURRENT || read.frame_offset == .PREV {
        if _, written := written_resources[read.resource_name]; !written {
          fmt.eprintf(
            "ERROR: Pass '%s' reads resource '%s' that no one writes\n",
            pass.name,
            read.resource_name,
          )
          return .DANGLING_READ
        }
      }
    }
  }

  // PREV reads require a corresponding NEXT write so the resource is
  // double-buffered and the previous frame's copy exists at runtime.
  next_written := make(map[string]bool)
  defer delete(next_written)

  for &pass in graph.pass_instances {
    for write in pass.writes {
      if write.frame_offset == .NEXT {
        next_written[write.resource_name] = true
      }
    }
  }

  for &pass in graph.pass_instances {
    for read in pass.reads {
      if read.frame_offset == .PREV {
        if !next_written[read.resource_name] {
          fmt.eprintf(
            "ERROR: Pass '%s' reads resource '%s' with .PREV but no pass writes it with .NEXT\n",
            pass.name,
            read.resource_name,
          )
          return .FRAME_OFFSET_INVALID
        }
      }
    }
  }

  // TODO: Add more validation
  // - Type matching (TextureId used with textures only)

  return .NONE
}

// ============================================================================
// Dependency Edge Building
// ============================================================================

build_dependency_edges :: proc(
  graph: ^Graph,
  resource_map: map[string]ResourceInstanceId,
  loc := #caller_location,
) -> map[PassInstanceId][dynamic]PassInstanceId {
  edges := make(map[PassInstanceId][dynamic]PassInstanceId)

  // Initialize edge list for every pass (so sinks appear in the map)
  for i in 0 ..< len(graph.pass_instances) {
    edges[PassInstanceId(i)] = make([dynamic]PassInstanceId)
  }

  // Pass 1: build version → writer map.
  // writers[name] is a list where writers[name][version-1] is the pass that produced that version.
  // Version numbers are 1-based and assigned sequentially in compile(), so the list grows by one
  // per write and has no gaps.
  writers := make(map[string][dynamic]PassInstanceId)
  defer {
    for _, list in writers {
      delete(list)
    }
    delete(writers)
  }

  for &pass, pass_idx in graph.pass_instances {
    for write in pass.writes {
      if write.frame_offset == .CURRENT && write.version > 0 {
        list := writers[write.resource_name]
        append(&list, PassInstanceId(pass_idx))
        writers[write.resource_name] = list
      }
    }
  }

  // Pass 2: for each CURRENT read, find the pass that produced the version being read.
  // This is an O(1) lookup: read.version is the exact version assigned during setup.
  // READ_WRITE chains (A-writes v1, B-reads v1 and writes v2, C-reads v2 ...) produce
  // the correct linear ordering A→B→C automatically.
  for &pass, pass_idx in graph.pass_instances {
    pass_id := PassInstanceId(pass_idx)
    for read in pass.reads {
      if read.frame_offset != .CURRENT || read.version == 0 do continue
      writer_list, found := writers[read.resource_name]
      if !found || int(read.version) > len(writer_list) do continue

      writer_id := writer_list[read.version - 1]
      if writer_id == pass_id do continue // skip self

      // Deduplicate
      already := false
      for existing in edges[writer_id] {
        if existing == pass_id {already = true;break}
      }
      if !already do append(&edges[writer_id], pass_id)
    }
  }

  when ODIN_DEBUG {
    log.debug("[GRAPH] Dependency edges:")
    for from_id, to_list in edges {
      from_pass := &graph.pass_instances[from_id]
      if len(to_list) == 0 {
        log.debugf("  %s → (no downstream consumers)", from_pass.name)
      } else {
        for to_id in to_list {
          to_pass := &graph.pass_instances[to_id]
          log.debugf("  %s → %s\n", from_pass.name, to_pass.name)
        }
      }
    }
  }

  return edges
}

// ============================================================================
// Dead Pass Elimination
// ============================================================================

eliminate_dead_passes :: proc(
  graph: ^Graph,
  edges: map[PassInstanceId][dynamic]PassInstanceId,
  loc := #caller_location,
) -> [dynamic]bool {
  // Mark all passes as dead initially
  live := make([dynamic]bool, len(graph.pass_instances))

  // Mark passes that write to external outputs as live
  for &pass, idx in graph.pass_instances {
    // Heuristic: passes with no downstream consumers are "sinks" (final outputs)
    if PassInstanceId(idx) not_in edges ||
       len(edges[PassInstanceId(idx)]) == 0 {
      live[idx] = true
      when ODIN_DEBUG {
        log.debugf("[GRAPH] Sink pass (no downstream): %s\n", pass.name)}
    }
  }

  // Build resource → writers map for O(1) lookup during backward propagation
  resource_writers := make(map[string][dynamic]PassInstanceId)
  defer {
    for _, list in resource_writers {
      delete(list)
    }
    delete(resource_writers)
  }
  for &pass, idx in graph.pass_instances {
    for write in pass.writes {
      list := resource_writers[write.resource_name]
      append(&list, PassInstanceId(idx))
      resource_writers[write.resource_name] = list
    }
  }

  // Propagate liveness backward through dependencies
  changed := true
  for changed {
    changed = false

    for &pass, idx in graph.pass_instances {
      if !live[idx] do continue

      for read in pass.reads {
        for writer_id in resource_writers[read.resource_name] {
          if !live[writer_id] {
            when ODIN_DEBUG {
              writer_name := graph.pass_instances[writer_id].name
              log.debugf(
                "[GRAPH] Marking %s as live (writes %s for %s)\n",
                writer_name,
                read.resource_name,
                pass.name,
              )
            }
            live[writer_id] = true
            changed = true
          }
        }
      }
    }
  }
  return live
}

// ============================================================================
// Topological Sort (Kahn's Algorithm)
// ============================================================================

topological_sort :: proc(
  graph: ^Graph,
  edges: map[PassInstanceId][dynamic]PassInstanceId,
  live: [dynamic]bool,
  loc := #caller_location,
) -> (
  sorted: [dynamic]PassInstanceId,
  err: CompileError,
) {
  // Compute in-degree for each pass
  in_degree := make([dynamic]int, len(graph.pass_instances))
  defer delete(in_degree)

  // Count incoming edges
  for from_id, to_list in edges {
    if !live[from_id] {
      continue
    }

    for to_id in to_list {
      if !live[to_id] {
        continue
      }
      in_degree[to_id] += 1
    }
  }

  // Initialize queue with nodes that have no incoming edges
  queue := make([dynamic]PassInstanceId)
  defer delete(queue)

  for i in 0 ..< len(in_degree) {
    if live[i] && in_degree[i] == 0 {
      append(&queue, PassInstanceId(i))
    }
  }

  // Process queue (FIFO — BFS-like ordering interleaves PER_CAMERA passes across cameras,
  // which prevents the aliaser from seeing non-overlapping lifetimes and aliasing
  // cam_0 / cam_1 gbuffers to the same VkImage, which would break multi-camera rendering).
  sorted = make([dynamic]PassInstanceId)
  head := 0

  for head < len(queue) {
    current := queue[head]
    head += 1

    append(&sorted, current)

    // Decrease in-degree of neighbors
    if current in edges {
      for neighbor in edges[current] {
        if !live[neighbor] {
          continue
        }

        in_degree[neighbor] -= 1

        if in_degree[neighbor] == 0 {
          append(&queue, neighbor)
        }
      }
    }
  }

  // Check if all live passes were processed (no cycles)
  live_count := 0
  for is_live in live {
    if is_live do live_count += 1
  }

  if len(sorted) < live_count {
    fmt.eprintf("ERROR: Cyclic graph detected\n")
    delete(sorted)
    return {}, .CYCLE_DETECTED
  }

  return sorted, .NONE
}
