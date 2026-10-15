package vulkan_backend

import rhi "../rhi"

import vk "vendor:vulkan"


// Brings frame_index's copy of every table up to date with render's: a region render wrote
// goes stale in every copy and is copied into each one as its frame comes up.
@(private)
tables_sync :: proc(b: ^Backend, desc: ^rhi.FrameDesc, frame_index: u32) {
  for t in rhi.Table {
    for &stale in b.table_stale[t] do stale |= desc.dirty[t]
    stale := &b.table_stale[t][frame_index]
    if stale^ == 0 do continue
    binding := TABLE_BINDING[t]
    dst := mapped(&b.frame_arena[frame_index], u8, vk.DeviceSize(b.table_offset[binding]), b.table_size[binding])
    src := desc.tables[t]
    size := (len(src) + rhi.TABLE_REGIONS - 1) / rhi.TABLE_REGIONS
    for r in 0 ..< rhi.TABLE_REGIONS {
      if stale^ & (1 << u64(r)) == 0 do continue
      lo := min(r * size, len(src))
      hi := min(lo + size, len(src))
      copy(dst[lo:hi], src[lo:hi])
    }
    stale^ = 0
  }
}
