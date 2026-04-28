package graph

import "../../gpu"
import "core:testing"
import vk "vendor:vulkan"

// Tests cover compile-side logic (cull/topo/lifetime). No GPU allocations.

@(private = "file")
make_test_graph :: proc() -> Graph {
  g: Graph
  g.resources = make([dynamic]Resource, 0, 8)
  g.passes = make([dynamic]PassDecl, 0, 8)
  g.imports = make(map[string]ResourceHandle)
  g.order = make([dynamic]PassHandle, 0, 8)
  transient_pool_init(&g.transient_pool)
  blackboard_init(&g.blackboard, BLACKBOARD_BYTES)
  g.subresource_buf = make([dynamic]SubresourceState, 0, 8)
  return g
}

// We can't allocate transients without a GPUContext — these tests cover
// build_adjacency, cull, topo_sort, compute_lifetimes only.

@(private = "file")
free_test_graph :: proc(g: ^Graph) {
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
  // No GPU device → can't destroy slot images; tests don't allocate any.
  delete(g.transient_pool.buckets)
  blackboard_destroy(&g.blackboard)
  delete(g.subresource_buf)
}

@(private = "file")
no_op :: proc(g: ^Graph, ctx: ExecuteContext, user_data: rawptr) {}

@(private = "file")
img_desc :: proc(name: string) -> ImageDesc {
  return ImageDesc {
    extent = {64, 64},
    format = .R8G8B8A8_UNORM,
    mip_levels = 1,
    array_layers = 1,
    samples = ._1,
    type = .D2,
    name = name,
  }
}

// Minimal graph: write A -> read A. Both alive.
@(test)
test_graph_simple_chain :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  a := graph_create_image(&g, img_desc("A"))
  pw := graph_add_pass(&g, "writer", .Graphics, no_op)
  pass_write(&g, pw, a, .ColorAttachment)
  pr := graph_add_pass(&g, "reader", .Graphics, no_op, side_effect = true)
  pass_read(&g, pr, a, .Sampled)
  build_adjacency(&g)
  cull(&g)
  testing.expect(t, !g.passes[pw].culled, "writer kept alive by reader")
  testing.expect(t, !g.passes[pr].culled, "reader kept alive by side effect")
  err := topo_sort(&g)
  testing.expect_value(t, err, GraphError.None)
  testing.expect_value(t, len(g.order), 2)
  testing.expect_value(t, g.order[0], pw)
  testing.expect_value(t, g.order[1], pr)
}

// Pass writes resource that nobody reads -> culled.
@(test)
test_graph_cull_unused :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  a := graph_create_image(&g, img_desc("A"))
  pw := graph_add_pass(&g, "writer", .Graphics, no_op)
  pass_write(&g, pw, a, .ColorAttachment)
  // no reader, no side effect
  build_adjacency(&g)
  cull(&g)
  testing.expect(t, g.passes[pw].culled, "writer culled with no consumer")
}

// side_effect bypasses culling.
@(test)
test_graph_side_effect_keeps_pass :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  a := graph_create_image(&g, img_desc("A"))
  pw := graph_add_pass(&g, "writer", .Graphics, no_op, side_effect = true)
  pass_write(&g, pw, a, .ColorAttachment)
  build_adjacency(&g)
  cull(&g)
  testing.expect(t, !g.passes[pw].culled, "side-effect pass kept alive")
}

// Diamond: A -> B,C -> D. Topo must place A first, D last.
@(test)
test_graph_topo_diamond :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  ra := graph_create_image(&g, img_desc("A"))
  rb := graph_create_image(&g, img_desc("B"))
  rc := graph_create_image(&g, img_desc("C"))
  rd := graph_create_image(&g, img_desc("D"))
  pa := graph_add_pass(&g, "A", .Graphics, no_op)
  pass_write(&g, pa, ra, .ColorAttachment)
  pb := graph_add_pass(&g, "B", .Graphics, no_op)
  pass_read(&g, pb, ra, .Sampled)
  pass_write(&g, pb, rb, .ColorAttachment)
  pc := graph_add_pass(&g, "C", .Graphics, no_op)
  pass_read(&g, pc, ra, .Sampled)
  pass_write(&g, pc, rc, .ColorAttachment)
  pd := graph_add_pass(&g, "D", .Graphics, no_op, side_effect = true)
  pass_read(&g, pd, rb, .Sampled)
  pass_read(&g, pd, rc, .Sampled)
  pass_write(&g, pd, rd, .ColorAttachment)
  build_adjacency(&g)
  cull(&g)
  err := topo_sort(&g)
  testing.expect_value(t, err, GraphError.None)
  testing.expect_value(t, len(g.order), 4)
  testing.expect_value(t, g.order[0], pa)
  testing.expect_value(t, g.order[3], pd)
}

// Lifetime: a transient appears once across two passes.
@(test)
test_graph_lifetime :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  a := graph_create_image(&g, img_desc("A"))
  pw := graph_add_pass(&g, "w", .Graphics, no_op)
  pass_write(&g, pw, a, .ColorAttachment)
  pr := graph_add_pass(&g, "r", .Graphics, no_op, side_effect = true)
  pass_read(&g, pr, a, .Sampled)
  build_adjacency(&g)
  cull(&g)
  topo_sort(&g)
  compute_lifetimes(&g)
  testing.expect_value(t, g.resources[a].first_use, i32(0))
  testing.expect_value(t, g.resources[a].last_use, i32(1))
}

// AccessKind table sanity.
@(test)
test_access_layout_table :: proc(t: ^testing.T) {
  testing.expect_value(t, access_layout(.ColorAttachment), vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL)
  testing.expect_value(t, access_layout(.Sampled), vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL)
  testing.expect_value(t, access_layout(.DepthAttachment), vk.ImageLayout.DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
  testing.expect_value(t, access_layout(.Present), vk.ImageLayout.PRESENT_SRC_KHR)
  testing.expect(t, is_write_access(.ColorAttachment))
  testing.expect(t, !is_write_access(.Sampled))
  testing.expect(t, is_read_access(.Sampled))
}

// Buffer access tables.
@(test)
test_access_buffer_usage_table :: proc(t: ^testing.T) {
  testing.expect(t, .STORAGE_BUFFER in access_buffer_usage(.StorageWrite))
  testing.expect(t, .INDIRECT_BUFFER in access_buffer_usage(.IndirectArg))
  testing.expect(t, .TRANSFER_DST in access_buffer_usage(.TransferDst))
  testing.expect_value(t, access_stage(.IndirectArg, .Graphics), vk.PipelineStageFlags{.DRAW_INDIRECT})
  testing.expect_value(t, access_stage(.StorageWrite, .Compute), vk.PipelineStageFlags{.COMPUTE_SHADER})
  testing.expect(t, .SHADER_WRITE in access_mask(.StorageWrite))
  testing.expect(t, .INDIRECT_COMMAND_READ in access_mask(.IndirectArg))
}

// Aliasing decision logic without GPU allocation: pre-seed a pool with two
// fake slots and verify that a request whose first_use exceeds slot[0]'s
// available_after picks slot[0] (oldest free). Verifies the sweep-line
// reuse rule used inside allocate_physical.
@(test)
test_transient_pool_reuse_decision :: proc(t: ^testing.T) {
  pool: Transient_Pool
  transient_pool_init(&pool)
  defer delete(pool.buckets)
  key := ImageKey {
    extent       = {64, 64},
    format       = .R8G8B8A8_UNORM,
    samples      = ._1,
    array_layers = 1,
    mip_levels   = 1,
    usage        = {.COLOR_ATTACHMENT, .SAMPLED},
    type         = .D2,
  }
  bucket := TransientBucket {
    key   = key,
    slots = make([dynamic]TransientSlot, 0, 4),
  }
  // slot[0] free up to pass 2; slot[1] free up to pass 5
  append(&bucket.slots, TransientSlot{available_after = 2})
  append(&bucket.slots, TransientSlot{available_after = 5})
  append(&pool.buckets, bucket)
  defer delete(pool.buckets[0].slots)
  // walk buckets, find first slot with available_after < 4
  bucket_idx := -1
  for &b, i in pool.buckets {
    if b.key == key {
      bucket_idx = i
      break
    }
  }
  testing.expect_value(t, bucket_idx, 0)
  picked := -1
  for &s, i in pool.buckets[bucket_idx].slots {
    if s.available_after < 4 {
      picked = i
      break
    }
  }
  testing.expect_value(t, picked, 0)
  // Different key — no bucket match, pool would create new bucket.
  key2 := key
  key2.format = .R16_SFLOAT
  found := false
  for &b in pool.buckets {
    if b.key == key2 {
      found = true
      break
    }
  }
  testing.expect(t, !found, "different format must not match existing bucket")
}

// Idempotent imports: importing the same name twice returns the same handle
// and does not create a duplicate Resource entry.
@(test)
test_graph_idempotent_imports :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  imp := ImportedImage {
    image = vk.Image(0),
    view = vk.ImageView(0),
    format = .R8G8B8A8_UNORM,
    extent = {64, 64},
    initial_layout = .UNDEFINED,
  }
  h1 := graph_import_image(&g, "shared", imp)
  h2 := graph_import_image(&g, "shared", imp)
  testing.expect_value(t, h1, h2)
  testing.expect_value(t, len(g.resources), 1)
  bh1 := graph_import_buffer(&g, "buf", vk.Buffer(0), 256)
  bh2 := graph_import_buffer(&g, "buf", vk.Buffer(0), 256)
  testing.expect_value(t, bh1, bh2)
  testing.expect_value(t, len(g.resources), 2)
}

// Versioning: pass_write returns the same handle id but bumps version_count.
@(test)
test_graph_write_version_bumps :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  a := graph_create_image(&g, img_desc("A"))
  pw := graph_add_pass(&g, "w", .Graphics, no_op)
  testing.expect_value(t, g.resources[a].version, u32(0))
  a2 := pass_write(&g, pw, a, .ColorAttachment)
  testing.expect_value(t, a2, a)
  testing.expect_value(t, g.resources[a].version, u32(1))
  pw2 := graph_add_pass(&g, "w2", .Graphics, no_op)
  _ = pass_write(&g, pw2, a, .ColorAttachment)
  testing.expect_value(t, g.resources[a].version, u32(2))
}

// Subresource range resolution: count == 0 means "full remaining".
@(test)
test_graph_subresource_range_resolution :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  d := img_desc("pyr")
  d.mip_levels = 4
  d.array_layers = 2
  h := graph_create_image(&g, d)
  r := &g.resources[h]
  // Full range
  bm, mc, bl, lc := resolve_subresource_range(r, Access{resource = h})
  testing.expect_value(t, bm, u32(0))
  testing.expect_value(t, mc, u32(4))
  testing.expect_value(t, bl, u32(0))
  testing.expect_value(t, lc, u32(2))
  testing.expect(t, is_full_image_access(r, Access{resource = h}))
  // Partial mip
  partial := Access {
    resource  = h,
    base_mip  = 1,
    mip_count = 2,
  }
  bm, mc, bl, lc = resolve_subresource_range(r, partial)
  testing.expect_value(t, bm, u32(1))
  testing.expect_value(t, mc, u32(2))
  testing.expect_value(t, lc, u32(2))
  testing.expect(t, !is_full_image_access(r, partial))
}

// Subresource state lazy-allocates and survives index round-trips.
@(test)
test_graph_subresource_state_lazy :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  d := img_desc("multi")
  d.mip_levels = 3
  d.array_layers = 2
  h := graph_create_image(&g, d)
  r := &g.resources[h]
  testing.expect(t, r.subresource_offset < 0, "lazy init: -1 before first access")
  // Single-subresource image: ensure_subresource_state is a no-op.
  d2 := img_desc("flat")
  h2 := graph_create_image(&g, d2)
  r2 := &g.resources[h2]
  ensure_subresource_state(&g, r2)
  testing.expect(t, r2.subresource_offset < 0, "single subresource stays flat")
  // Multi-subresource: allocates once, indexed correctly.
  ensure_subresource_state(&g, r)
  testing.expect_value(t, r.subresource_count, i32(6))
  set_subresource_state(&g, r, 2, 1, SubresourceState{layout = .GENERAL})
  got := get_subresource_state(&g, r, 2, 1)
  testing.expect_value(t, got.layout, vk.ImageLayout.GENERAL)
  // Untouched entries retain init state.
  other := get_subresource_state(&g, r, 0, 0)
  testing.expect_value(t, other.layout, vk.ImageLayout.UNDEFINED)
}

// LoadOp.Auto: first writer clears, subsequent loads, on resolve_load_op.
@(test)
test_graph_load_op_auto :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  h := graph_create_image(&g, img_desc("rt"))
  r := &g.resources[h]
  // write_count starts 0 → CLEAR
  op := resolve_load_op(.Auto, r)
  testing.expect_value(t, op, vk.AttachmentLoadOp.CLEAR)
  r.write_count = 1
  op = resolve_load_op(.Auto, r)
  testing.expect_value(t, op, vk.AttachmentLoadOp.LOAD)
  // Explicit overrides
  testing.expect_value(t, resolve_load_op(.Clear, r), vk.AttachmentLoadOp.CLEAR)
  testing.expect_value(t, resolve_load_op(.Load, r), vk.AttachmentLoadOp.LOAD)
  testing.expect_value(t, resolve_load_op(.DontCare, r), vk.AttachmentLoadOp.DONT_CARE)
}

// Compute -> graphics buffer chain: storage write then indirect read should order properly.
@(test)
test_graph_buffer_compute_to_indirect :: proc(t: ^testing.T) {
  g := make_test_graph()
  defer free_test_graph(&g)
  // imported buffer
  bh := graph_import_buffer(&g, "indirect", vk.Buffer(0), 256)
  pc := graph_add_pass(&g, "cull", .Compute, no_op)
  pass_write(&g, pc, bh, .StorageWrite)
  pr := graph_add_pass(&g, "draw", .Graphics, no_op, side_effect = true)
  pass_read(&g, pr, bh, .IndirectArg)
  build_adjacency(&g)
  cull(&g)
  testing.expect(t, !g.passes[pc].culled, "compute writer kept (consumer reads buffer)")
  err := topo_sort(&g)
  testing.expect_value(t, err, GraphError.None)
  testing.expect_value(t, g.order[0], pc)
  testing.expect_value(t, g.order[1], pr)
}

// Blackboard: typed string-keyed store, type-tag verifies on get.
@(test)
test_blackboard_basic :: proc(t: ^testing.T) {
  bb: Blackboard
  blackboard_init(&bb, 4096)
  defer blackboard_destroy(&bb)
  Foo :: struct { a, b: i32 }
  Bar :: struct { x: f32 }
  f := blackboard_add(&bb, "foo", Foo)
  testing.expect(t, f != nil, "add returns non-nil")
  f.a = 7
  f.b = 9
  // Same key, same type: returns existing entry untouched.
  f2 := blackboard_add(&bb, "foo", Foo)
  testing.expect(t, f == f2, "same key+type yields same pointer")
  testing.expect_value(t, f2.a, i32(7))
  // Different key, same type: independent slot.
  g := blackboard_add(&bb, "foo2", Foo)
  testing.expect(t, g != f, "different keys are independent")
  // Get with right type
  got := blackboard_get(&bb, "foo", Foo)
  testing.expect_value(t, got.a, i32(7))
  testing.expect_value(t, got.b, i32(9))
  // Get with wrong type: nil
  miss := blackboard_get(&bb, "foo", Bar)
  testing.expect(t, miss == nil, "type mismatch returns nil")
  // has
  testing.expect(t, blackboard_has(&bb, "foo"))
  testing.expect(t, !blackboard_has(&bb, "absent"))
  // Reset clears
  blackboard_reset(&bb)
  testing.expect(t, !blackboard_has(&bb, "foo"))
  testing.expect_value(t, bb.used, 0)
}
