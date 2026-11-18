#+build !js
#+private file
package render

import "../containers"
import "core:testing"

TINY :: Config {
  nodes            = 4,
  meshes           = 2,
  materials        = 2,
  lights           = 2,
  emitters         = 2,
  force_fields     = 2,
  textures         = 2,
  bones            = 4,
  skinned_vertices = 4,
  sprite_frames    = 4,
  vertices         = 4,
  indices          = 4,
  overlay_vertices = 4,
  overlay_indices  = 4,
  gpu_buffers      = 2,
  shaders          = 2,
  particles        = 256,
  debug_lines      = 4,
  shadow_maps      = 2,
}

// The renderer's CPU side, no device: tables, pools and ranges at TINY's reserves.
cpu_renderer :: proc(config := TINY) -> ^Renderer {
  r := new(Renderer)
  r.config = config
  r.max_shadow_views = shadow_view_count(config)
  tables_init(r, table_reserves(config))
  pools_init(r)
  containers.ranges_init(&r.bone_ranges, u32(table_capacity(r, .BONES)))
  containers.ranges_init(&r.sprite_frame_ranges, u32(table_capacity(r, .SPRITE_FRAMES)))
  containers.ranges_init(&r.skin_ranges, u32(table_capacity(r, .SKIN_OWNERS)))
  return r
}

cpu_renderer_destroy :: proc(r: ^Renderer) {
  tables_destroy(r)
  for &s in r.slots do containers.slots_destroy(&s)
  containers.ranges_destroy(&r.bone_ranges)
  containers.ranges_destroy(&r.sprite_frame_ranges)
  containers.ranges_destroy(&r.skin_ranges)
  delete(r.texture_targets)
  delete(r.gpu_buffers)
  delete(r.shaders)
  free(r)
}

@(test)
test_table_grow_keeps_entries_and_marks :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  materials := write_table(r, .MATERIALS, Material)
  materials[1].roughness_factor = 0.25
  mark_dirty(r, .MATERIALS, 1)
  testing.expect(t, table_grow(r, .MATERIALS, 10_000))
  testing.expect(t, table_capacity(r, .MATERIALS) >= 10_000)
  testing.expect_value(t, write_table(r, .MATERIALS, Material)[1].roughness_factor, 0.25)
  testing.expect(t, r.dirty[.MATERIALS][0] & 1 != 0, "a mark made before growth survives it")
  regions := (len(r.tables[.MATERIALS]) + TABLE_REGION_BYTES - 1) / TABLE_REGION_BYTES
  testing.expect(t, len(r.dirty[.MATERIALS]) * 64 >= regions)
  for f in 0 ..< FRAMES_IN_FLIGHT do testing.expect(t, len(r.table_stale[.MATERIALS][f]) * 64 >= regions)
  tables_stale_all(r, .MATERIALS, 0)
  region: int
  runs, bytes := 0, 0
  for lo, hi in tables_next_stale(r, .MATERIALS, 0, &region) {
    runs += 1
    bytes += hi - lo
  }
  testing.expect_value(t, runs, 1)
  testing.expect_value(t, bytes, len(r.tables[.MATERIALS]))
  testing.expect(t, !r.any_stale[.MATERIALS][0], "walking the stale runs clears them")
}

@(test)
test_table_pointer_survives_growth :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  if r.reserved[.MATERIALS] == nil do return
  m := &write_table(r, .MATERIALS, Material)[1]
  testing.expect(t, table_grow(r, .MATERIALS, 100_000))
  m.metallic_factor = 0.5
  testing.expect_value(t, write_table(r, .MATERIALS, Material)[1].metallic_factor, 0.5)
}

@(test)
test_mark_dirty_across_the_old_end :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  old := table_capacity(r, .NODES)
  testing.expect(t, table_grow(r, .NODES, 5_000))
  tables_publish(r)
  for f in 0 ..< FRAMES_IN_FLIGHT {
    region: int
    for _, _ in tables_next_stale(r, .NODES, f, &region) {}
  }
  for i in ([?]int{old - 1, old, 4_999}) do mark_dirty(r, .NODES, i)
  mark_dirty(r, .NODES, old - 2, 4)
  tables_publish(r)
  stride := TABLE_STRIDES[.NODES]
  for i in ([?]int{old - 2, old - 1, old, old + 1, 4_999}) {
    first, last := i * stride / TABLE_REGION_BYTES, ((i + 1) * stride - 1) / TABLE_REGION_BYTES
    for reg in first ..= last {
      testing.expectf(t, r.table_stale[.NODES][0][reg / 64] & (1 << u64(reg % 64)) != 0, "entry %d region %d is stale", i, reg)
    }
  }
}

@(test)
test_pool_alloc_past_every_reserve :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  for p in Pool {
    want := min(1000, int(POOLS[p].ceiling) - 1)
    for i in 0 ..< want {
      index, ok := pool_alloc(r, p)
      if !testing.expectf(t, ok, "%v: alloc %d of %d", p, i, want) do break
      if POOLS[p].rows do testing.expectf(t, int(index) < table_capacity(r, POOLS[p].table), "%v: row %d past its table", p, index)
    }
    testing.expectf(t, containers.slots_count(&r.slots[p]) == u32(want), "%v: %d live", p, containers.slots_count(&r.slots[p]))
  }
  testing.expect(t, len(r.texture_targets) >= 1000)
  testing.expect(t, len(r.gpu_buffers) >= 1000)
  testing.expect(t, len(r.shaders) >= 1000)
}

@(test)
test_pool_ceilings_refuse_cleanly :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  for _ in 1 ..< MAX_ACTIVE_CAMERAS do pool_alloc(r, .CAMERAS)
  _, ok := pool_alloc(r, .CAMERAS)
  testing.expect(t, !ok, "no camera past MAX_ACTIVE_CAMERAS")
  for _ in 0 ..< MAX_MATERIAL_SHADERS do pool_alloc(r, .MATERIAL_SHADERS)
  _, ok = pool_alloc(r, .MATERIAL_SHADERS)
  testing.expect(t, !ok, "no material shader past MAX_MATERIAL_SHADERS")
  testing.expect(t, !table_grow(r, .MATERIALS, 1 << 24 + 1), "materials stop at 2^24")
  testing.expect(t, !table_grow(r, .BATCHES, 1 << 20 + 1), "batches stop at 2^20")
  testing.expect(t, !table_grow(r, .NODES, 1 << 24 + 1), "slots stop at 2^24: first_instance holds 24 bits of node")
  testing.expect(t, slot_node(r, 1 << 24) == nil)
}

@(test)
test_slots_past_the_old_cap :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  n := slot_node(r, 100_000)
  testing.expect(t, n != nil)
  testing.expect(t, table_capacity(r, .NODES) > 100_000)
  testing.expect_value(t, r.node_count, 100_001)
  when !BINDLESS do testing.expect(t, table_capacity(r, .NODE_BATCH) >= table_capacity(r, .NODES))
}

@(test)
test_ranges_grow_their_tables :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  firsts: [dynamic]u32
  defer delete(firsts)
  for _ in 0 ..< 50 {
    first, ok := ranges_alloc_growing(r, &r.bone_ranges, .BONES, 69)
    if !testing.expect(t, ok) do return
    append(&firsts, first)
  }
  testing.expect(t, table_capacity(r, .BONES) >= 50 * 69)
  testing.expect_value(t, int(r.bone_ranges.capacity), table_capacity(r, .BONES))
  for first, i in firsts {
    testing.expect_value(t, first, u32(i * 69))
    testing.expect_value(t, containers.ranges_size(&r.bone_ranges, first), 69)
  }
  big, ok := ranges_alloc_growing(r, &r.skin_ranges, .SKIN_OWNERS, 200_000)
  testing.expect(t, ok && big == 0, "one run larger than the whole reserve")
  frames, frames_ok := ranges_alloc_growing(r, &r.sprite_frame_ranges, .SPRITE_FRAMES, 1000)
  testing.expect(t, frames_ok && frames == 0)
}

@(test)
test_write_entry_marks_only_changes :: proc(t: ^testing.T) {
  r := cpu_renderer()
  defer cpu_renderer_destroy(r)
  write_entry(r, .LIGHTS, 1, Light{intensity = 2})
  testing.expect(t, r.any_dirty[.LIGHTS])
  tables_publish(r)
  write_entry(r, .LIGHTS, 1, Light{intensity = 2})
  testing.expect(t, !r.any_dirty[.LIGHTS], "an unchanged entry is not marked")
}

@(test)
test_shadow_views_fit_the_tag :: proc(t: ^testing.T) {
  testing.expect(t, shadow_view_count({shadow_maps = MAX_SHADOW_MAPS}) < 1 << 8)
  testing.expect_value(t, TABLE_CEILINGS[.NODES], 1 << 24)
  // shader/shadow.slang unpacks node = instance & 0xFFFFFF, view = SHADOW_VIEW_BASE + instance >> 24
  node, view := u32(1 << 24 - 1), u32(shadow_view_count({shadow_maps = MAX_SHADOW_MAPS}) - 1)
  packed := node | view << 24
  testing.expect_value(t, packed & 0xFFFFFF, node)
  testing.expect_value(t, packed >> 24, view)
}
