package wgpu_backend

import rhi "../rhi"

import wgpu "vendor:wgpu"









// Render's node and material entries, as far as the CPU side of the draw loop reads them.
@(private)
NodeData :: struct #packed {
  world_matrix: matrix[4, 4]f32,
  material_id:  u32,
  mesh_id:      u32,
  _:            u32,
  flags:        u32,
}
#assert(size_of(NodeData) == 80)

@(private)
MaterialData :: struct {
  _:    [15]u32,
  type: rhi.MaterialType,
}
#assert(size_of(MaterialData) == 64)

// A draw batch (Table.BATCHES): render's Batch.
@(private)
BatchData :: struct {
  mesh_id:        u32,
  material_id:    u32,
  first_instance: u32,
  capacity:       u32,
}
#assert(size_of(BatchData) == 16)

// The VISIBLE node flag: every view requires it.
@(private)
NODE_VISIBLE :: 1

@(private)
MESH_STREAM_USAGE := [rhi.MeshStream]wgpu.BufferUsageFlags {
  // wireframe and random-color materials pull vertices and indices
  .VERTEX   = {.Vertex, .Storage, .CopyDst},
  .INDEX    = {.Index, .Storage, .CopyDst},
  .SKINNING = {.Storage, .CopyDst},
}

// table reads t from the frame render described.
@(private)
table :: #force_inline proc(desc: ^rhi.FrameDesc, t: rhi.Table, $T: typeid) -> []T {
  return ([^]T)(raw_data(desc.tables[t]))[:len(desc.tables[t]) / size_of(T)]
}

@(private)
tables_init :: proc(b: ^Backend, table_size: [rhi.Table]int, mesh_size: [rhi.MeshStream]int) {
  for &buffer, t in b.table_buffers {
    // a binding may not be empty
    buffer = buffer_create(b, max(table_size[t], 16), {.Storage, .CopyDst})
  }
  for &buffer, s in b.mesh_buffers do buffer = buffer_create(b, mesh_size[s], MESH_STREAM_USAGE[s])
}

// Uploads every region render wrote since the last frame; WriteBuffer takes 4-byte multiples.
@(private)
tables_upload :: proc(b: ^Backend, desc: ^rhi.FrameDesc) {
  for t in rhi.Table {
    dirty := desc.dirty[t]
    if dirty == 0 do continue
    src := desc.tables[t]
    size := (len(src) + rhi.TABLE_REGIONS - 1) / rhi.TABLE_REGIONS
    r := 0
    for r < rhi.TABLE_REGIONS {
      if dirty & (1 << u64(r)) == 0 {
        r += 1
        continue
      }
      first := r
      for r < rhi.TABLE_REGIONS && dirty & (1 << u64(r)) != 0 do r += 1
      lo := min(first * size, len(src)) &~ 3
      hi := min((min(r * size, len(src)) + 3) &~ 3, len(src))
      if hi > lo do wgpu.QueueWriteBuffer(b.queue, b.table_buffers[t], u64(lo), &src[lo], uint(hi - lo))
    }
  }
}

// mesh_write uploads data at element `first` of stream's buffer before the next frame.
mesh_write :: proc(b: ^Backend, stream: rhi.MeshStream, data: []$T, first: u32) -> bool {
  #assert(size_of(T) % 4 == 0)
  if len(data) == 0 do return true
  wgpu.QueueWriteBuffer(b.queue, b.mesh_buffers[stream], u64(first) * size_of(T), raw_data(data), uint(len(data) * size_of(T)))
  return true
}

@(private)
buffer_create :: proc(b: ^Backend, size: int, usage: wgpu.BufferUsageFlags) -> wgpu.Buffer {
  return wgpu.DeviceCreateBuffer(b.device, &{usage = usage, size = u64((size + 3) &~ 3)})
}
