#+build !js
#+private file
package render

import "core:testing"
import "rhi"

COLOR_DESC :: TextureDesc{extent = {64, 64}, format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}}
HDR_DESC :: TextureDesc{extent = {64, 64}, format = .RGBA16F, usage = {.COLOR_TARGET, .SAMPLED, .STORAGE}}

tex :: proc(h: u32, a: Access) -> GraphUse {return {h, .TEXTURE, a}}
buf :: proc(h: u32, a: Access) -> GraphUse {return {h, .BUFFER, a}}
tr :: proc(h: u32, a: Access) -> GraphUse {return {h, .TRANSIENT, a}}

add :: proc(g: ^FrameGraph, type: PassType, uses: ..GraphUse) -> u32 {
  graph_pass(g, "pass", type, .SKIN, 0, uses)
  return u32(len(g.passes) - 1)
}

batch_of :: proc(g: ^FrameGraph, pass: u32) -> int {
  for bt, b in g.batches do if pass >= bt.first && pass < bt.first + bt.count do return b
  return -1
}

@(test)
test_graph_empty :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  graph_transient(&g, COLOR_DESC)
  graph_compile(&g)
  testing.expect_value(t, len(g.batches), 0)
  testing.expect_value(t, len(g.physical), 0)
  testing.expect_value(t, g.placement[0], GRAPH_NONE)
}

@(test)
test_graph_reads_group :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  a := graph_transient(&g, COLOR_DESC)
  w := add(&g, .RASTER, tr(a, .COLOR))
  r1 := add(&g, .COMPUTE, tr(a, .READ), buf(1, .WRITE))
  r2 := add(&g, .RASTER, tr(a, .READ), buf(2, .WRITE))
  graph_compile(&g)
  testing.expect_value(t, len(g.batches), 2)
  testing.expect_value(t, batch_of(&g, w), 0)
  testing.expect_value(t, batch_of(&g, r1), 1)
  testing.expect_value(t, batch_of(&g, r2), 1)
  // one barrier makes the color writes visible to both readers' stages
  b := g.batches[1].barrier
  testing.expect(t, b.src_stage == {.COLOR_ATTACHMENT_OUTPUT})
  testing.expect(t, b.src_access == {.COLOR_ATTACHMENT_WRITE})
  testing.expect(t, b.dst_stage == {.COMPUTE_SHADER, .VERTEX_SHADER, .FRAGMENT_SHADER})
  // the transient begins with a discard where it is first written
  testing.expect_value(t, g.batches[0].discard_count, 1)
  testing.expect_value(t, g.discards[g.batches[0].first_discard], g.placement[a])
  // the first batch waits on the previous frame
  testing.expect(t, .COMPUTE_SHADER in g.batches[0].barrier.dst_stage)
}

@(test)
test_graph_writes_serialize :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  for _ in 0 ..< 3 do add(&g, .COMPUTE, buf(7, .WRITE))
  graph_compile(&g)
  testing.expect_value(t, len(g.batches), 3)
  for b in 1 ..< 3 {
    testing.expect(t, g.batches[b].barrier.src_access == {.SHADER_WRITE})
    testing.expect(t, g.batches[b].barrier.dst_stage == {.COMPUTE_SHADER})
  }
}

@(test)
test_graph_keeps_declaration_order :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  add(&g, .COMPUTE, buf(1, .WRITE))
  add(&g, .COMPUTE, buf(1, .READ))
  // independent of both, it still runs after them: in the batch of the pass before it
  free := add(&g, .COMPUTE, buf(2, .WRITE))
  rewrite := add(&g, .COMPUTE, buf(1, .WRITE))
  graph_compile(&g)
  testing.expect_value(t, batch_of(&g, free), 1)
  testing.expect_value(t, batch_of(&g, rewrite), 2)
  // write after read: an execution dependency, nothing to make visible from the reads
  testing.expect(t, g.batches[2].barrier.src_stage == {.COMPUTE_SHADER})
  testing.expect(t, g.batches[2].barrier.src_access == {})
}

@(test)
test_graph_independent_passes_share_batch :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  for _ in 0 ..< 4 do add(&g, .COMPUTE, tr(graph_transient(&g, HDR_DESC), .WRITE))
  graph_compile(&g)
  testing.expect_value(t, len(g.batches), 1)
  testing.expect_value(t, g.batches[0].count, 4)
  testing.expect_value(t, len(g.physical), 4)
}

// Cameras one after another: each camera's G-buffer overlaps only the camera before it, so any
// number of cameras takes two sets.
@(test)
test_graph_cameras_share_two_sets :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  CAMERAS :: 5
  for c in 0 ..< u32(CAMERAS) {
    normal, albedo := graph_transient(&g, COLOR_DESC), graph_transient(&g, COLOR_DESC)
    depth, final := 100 + c, 200 + c
    add(&g, .RASTER, tr(normal, .COLOR), tr(albedo, .COLOR), tex(depth, .DEPTH))
    add(&g, .COMPUTE, tr(normal, .READ), tr(albedo, .READ), tex(depth, .READ), tex(final, .WRITE))
  }
  graph_compile(&g)
  testing.expect_value(t, len(g.batches), CAMERAS + 1)
  testing.expect_value(t, len(g.physical), 4)
}

@(test)
test_graph_transients_share_disjoint_lifetimes :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  a, c, b := graph_transient(&g, COLOR_DESC), graph_transient(&g, HDR_DESC), graph_transient(&g, COLOR_DESC)
  add(&g, .RASTER, tr(a, .COLOR))
  add(&g, .COMPUTE, tr(a, .READ), tr(c, .WRITE))
  handover := add(&g, .RASTER, tr(c, .READ), tr(b, .COLOR))
  add(&g, .RASTER, tr(b, .READ), tex(u32(max(rhi.TextureHandle)), .COLOR))
  graph_compile(&g)
  testing.expect_value(t, len(g.batches), 4)
  testing.expect_value(t, len(g.physical), 2)
  testing.expect_value(t, g.placement[a], g.placement[b])
  testing.expect(t, g.placement[c] != g.placement[a])
  // b takes over a's texture after a's last read: discarded, and ordered after that read
  bt := g.batches[batch_of(&g, handover)]
  testing.expect_value(t, bt.discard_count, 1)
  testing.expect_value(t, g.discards[bt.first_discard], g.placement[b])
  testing.expect(t, .COMPUTE_SHADER in bt.barrier.src_stage)
}

@(test)
test_graph_transients_overlapping_stay_apart :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  a, b := graph_transient(&g, COLOR_DESC), graph_transient(&g, COLOR_DESC)
  add(&g, .RASTER, tr(a, .COLOR))
  add(&g, .RASTER, tr(b, .COLOR))
  add(&g, .COMPUTE, tr(a, .READ), tr(b, .READ), buf(1, .WRITE))
  graph_compile(&g)
  testing.expect_value(t, len(g.physical), 2)
  testing.expect(t, g.placement[a] != g.placement[b])
}

@(test)
test_graph_concurrent_writes_group :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  for _ in 0 ..< 3 do add(&g, .COMPUTE, buf(1, .WRITE_CONCURRENT))
  draw := add(&g, .RASTER, buf(1, .INDIRECT))
  graph_compile(&g)
  testing.expect_value(t, len(g.batches), 2)
  testing.expect_value(t, g.batches[0].count, 3)
  testing.expect_value(t, batch_of(&g, draw), 1)
  testing.expect(t, g.batches[1].barrier.dst_access == {.INDIRECT_READ})
}

@(test)
test_graph_uses_of_one_resource_merge :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  add(&g, .COMPUTE, buf(1, .WRITE))
  // dispatched from its arguments while reading them: one entry, both stages waiting
  both := add(&g, .COMPUTE, buf(1, .INDIRECT), buf(1, .READ))
  // a texture and a buffer of one handle are different resources
  other := add(&g, .COMPUTE, tex(1, .WRITE))
  graph_compile(&g)
  testing.expect_value(t, batch_of(&g, both), 1)
  testing.expect_value(t, batch_of(&g, other), 1)
  b := g.batches[1].barrier
  testing.expect(t, b.dst_stage == {.DRAW_INDIRECT, .COMPUTE_SHADER})
  testing.expect(t, b.dst_access == {.INDIRECT_READ, .SHADER_READ})
}

@(test)
test_graph_recompile_is_stable :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  declare :: proc(g: ^FrameGraph) {
    graph_reset(g)
    prev := graph_transient(g, COLOR_DESC)
    add(g, .RASTER, tr(prev, .COLOR))
    for _ in 0 ..< 8 {
      next := graph_transient(g, COLOR_DESC)
      add(g, .RASTER, tr(prev, .READ), tr(next, .COLOR))
      prev = next
    }
    add(g, .RASTER, tr(prev, .READ), tex(1, .COLOR))
  }
  declare(&g)
  graph_compile(&g)
  // a ping-pong chain needs two textures
  testing.expect_value(t, len(g.physical), 2)
  placement := make([]u32, len(g.placement), context.temp_allocator)
  copy(placement, g.placement[:])
  declare(&g)
  graph_compile(&g)
  testing.expect_value(t, len(g.physical), 2)
  for p, i in placement do testing.expect_value(t, g.placement[i], p)
}

@(test)
test_graph_many_passes_and_resources :: proc(t: ^testing.T) {
  N :: 1 << 17
  // past u16, wide: every pass writes its own transient, all in one batch
  {
    g: FrameGraph
    defer graph_destroy(&g)
    for _ in 0 ..< N do add(&g, .COMPUTE, tr(graph_transient(&g, HDR_DESC), .WRITE))
    graph_compile(&g)
    testing.expect_value(t, len(g.batches), 1)
    testing.expect_value(t, len(g.physical), N)
    testing.expect_value(t, len(g.discards), N)
  }
  // past u16, deep: each pass reads the last one's transient and writes a new one
  {
    g: FrameGraph
    defer graph_destroy(&g)
    prev := graph_transient(&g, HDR_DESC)
    add(&g, .COMPUTE, tr(prev, .WRITE))
    for _ in 1 ..< N {
      next := graph_transient(&g, HDR_DESC)
      add(&g, .COMPUTE, tr(prev, .READ), tr(next, .WRITE))
      prev = next
    }
    graph_compile(&g)
    testing.expect_value(t, len(g.batches), N)
    testing.expect_value(t, len(g.physical), 2)
  }
}

@(test)
test_graph_transient_read_first_asserts :: proc(t: ^testing.T) {
  g: FrameGraph
  defer graph_destroy(&g)
  testing.expect_assert(t, "frame graph: a transient texture is read before any pass writes it")
  add(&g, .COMPUTE, tr(graph_transient(&g, COLOR_DESC), .READ))
  graph_compile(&g)
}
