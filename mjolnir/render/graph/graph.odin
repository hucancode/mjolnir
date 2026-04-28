package graph

import "../../gpu"
import vk "vendor:vulkan"

BLACKBOARD_BYTES :: 64 * 1024

Graph :: struct {
  resources:        [dynamic]Resource,
  passes:           [dynamic]PassDecl,
  imports:          map[string]ResourceHandle,
  order:            [dynamic]PassHandle,
  frame_index:      u32,
  // pooled transient images, alias-reused across resources per frame
  transient_pool:   Transient_Pool,
  // typed key-value store; shared across passes within a frame
  blackboard:       Blackboard,
  // owned per-subresource state buffer; resources index into this with
  // `subresource_offset` (>= 0) and `subresource_count`.
  subresource_buf:  [dynamic]SubresourceState,
}

graph_init :: proc(g: ^Graph) -> vk.Result {
  g.resources = make([dynamic]Resource, 0, 32)
  g.passes = make([dynamic]PassDecl, 0, 32)
  g.imports = make(map[string]ResourceHandle)
  g.order = make([dynamic]PassHandle, 0, 32)
  transient_pool_init(&g.transient_pool)
  blackboard_init(&g.blackboard, BLACKBOARD_BYTES)
  g.subresource_buf = make([dynamic]SubresourceState, 0, 64)
  return .SUCCESS
}

graph_shutdown :: proc(g: ^Graph, gctx: ^gpu.GPUContext) {
  transient_pool_shutdown(&g.transient_pool, gctx)
  for &p in g.passes {
    delete(p.reads)
    delete(p.writes)
  }
  for &r in g.resources {
    delete(r.producers)
    delete(r.consumers)
  }
  delete(g.resources)
  delete(g.passes)
  delete(g.imports)
  delete(g.order)
  blackboard_destroy(&g.blackboard)
  delete(g.subresource_buf)
}

graph_begin_frame :: proc(g: ^Graph, gctx: ^gpu.GPUContext, frame_index: u32) {
  for &p in g.passes {
    delete(p.reads)
    delete(p.writes)
  }
  for &r in g.resources {
    delete(r.producers)
    delete(r.consumers)
  }
  clear(&g.resources)
  clear(&g.passes)
  clear(&g.imports)
  clear(&g.order)
  transient_pool_reset(&g.transient_pool)
  blackboard_reset(&g.blackboard)
  clear(&g.subresource_buf)
  g.frame_index = frame_index
}

// Compile + execute the currently registered passes, then clear DAG so more
// passes can be registered. Blackboard and transient pool persist until next
// begin_frame.
graph_flush :: proc(
  g: ^Graph,
  gctx: ^gpu.GPUContext,
  cmd: vk.CommandBuffer,
) -> (vk.Result, GraphError) {
  if len(g.passes) == 0 do return .SUCCESS, .None
  res, err := graph_compile(g, gctx)
  if res != .SUCCESS || err != .None do return res, err
  if r := graph_execute(g, cmd); r != .SUCCESS do return r, .None
  // Free transient slot reservations from this flush so a subsequent flush in
  // the same frame can reuse them. Slot images and their layout state survive.
  transient_pool_reset(&g.transient_pool)
  for &p in g.passes {
    delete(p.reads)
    delete(p.writes)
  }
  for &r in g.resources {
    delete(r.producers)
    delete(r.consumers)
  }
  clear(&g.resources)
  clear(&g.passes)
  clear(&g.imports)
  clear(&g.order)
  // Subresource state freed: handles invalidated alongside resources.
  clear(&g.subresource_buf)
  return .SUCCESS, .None
}

graph_add_pass :: proc(
  g: ^Graph,
  name: string,
  kind: PassKind,
  execute: ExecuteProc,
  user_data: rawptr = nil,
  side_effect: bool = false,
  manual_rendering: bool = false,
) -> PassHandle {
  p := PassDecl {
    name             = name,
    kind             = kind,
    reads            = make([dynamic]Access, 0, 4),
    writes           = make([dynamic]Access, 0, 4),
    side_effect      = side_effect,
    manual_rendering = manual_rendering,
    execute          = execute,
    user_data        = user_data,
  }
  append(&g.passes, p)
  return PassHandle(len(g.passes) - 1)
}

pass_read :: proc(
  g: ^Graph,
  p: PassHandle,
  r: ResourceHandle,
  kind: AccessKind,
  base_mip: u32 = 0,
  mip_count: u32 = 0,
  base_layer: u32 = 0,
  layer_count: u32 = 0,
) {
  append(
    &g.passes[p].reads,
    Access{r, kind, base_mip, mip_count, base_layer, layer_count, .Auto, .Auto},
  )
}

// pass_write declares a write access. Returns the same handle bumped to a new
// version (FrameGraph rename semantic). Callers may rebind their local variable
// to the returned handle: subsequent reads then refer to the post-write version,
// which makes the data flow self-documenting and lets the graph diagnose
// stale-handle reads in future versions of this API.
//
//   pos := graph_create_image(&g, ...)
//   pos = pass_write(&g, geo_pass, pos, .ColorAttachment)  // pos now v1
//   pass_read(&g, light_pass, pos, .Sampled)               // reads v1
pass_write :: proc(
  g: ^Graph,
  p: PassHandle,
  r: ResourceHandle,
  kind: AccessKind,
  base_mip: u32 = 0,
  mip_count: u32 = 0,
  base_layer: u32 = 0,
  layer_count: u32 = 0,
  load_op: LoadOp = .Auto,
  store_op: StoreOp = .Auto,
) -> ResourceHandle {
  append(
    &g.passes[p].writes,
    Access{r, kind, base_mip, mip_count, base_layer, layer_count, load_op, store_op},
  )
  g.resources[r].version += 1
  return r
}
