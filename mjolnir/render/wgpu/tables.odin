package wgpu_backend

import wgpu "vendor:wgpu"

MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128

// The views table holds every camera at CAMERA_VIEW_BASE + camera, then the shadow views.
CAMERA_VIEW_BASE :: 0
SHADOW_VIEW_BASE :: MAX_ACTIVE_CAMERAS
MAX_VIEWS :: MAX_ACTIVE_CAMERAS + MAX_SHADOW_VIEWS

// The tables render writes; their sizes are given at init. The entries' layouts are render's,
// mirrored by the shaders (shader/common.wgsl).
Table :: enum {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  EMITTERS,
  FORCEFIELDS,
  LIGHTS,
  DEBUG_LINES,
}

// TABLE_REGIONS is the granularity of FrameDesc.dirty: region r of a table of n bytes is
// bytes [r * size, (r + 1) * size), size = ceil(n / TABLE_REGIONS).
TABLE_REGIONS :: 64

// One buffer per stream, sub-allocated by render.
MeshStream :: enum {
  VERTEX,
  INDEX,
  SKINNING,
}

// Vertex is the mesh vertex format.
Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  tangent:  [4]f32, // xyz = tangent, w = handedness (for bitangent reconstruction)
}

// MeshData is a mesh as the cull shader reads it from the mesh table.
MeshData :: struct {
  aabb_min:        [3]f32,
  index_count:     u32,
  aabb_max:        [3]f32,
  first_index:     u32,
  vertex_offset:   i32,
  skinning_offset: u32,
  flags:           MeshFlagSet,
  vertex_count:    u32,
}

MeshFlag :: enum u32 {
  SKINNED,
}
MeshFlagSet :: bit_set[MeshFlag;u32]

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
  type: MaterialType,
}
#assert(size_of(MaterialData) == 64)

// The VISIBLE node flag: every view requires it.
@(private)
NODE_VISIBLE :: 1

@(private)
MESH_STREAM_USAGE := [MeshStream]wgpu.BufferUsageFlags {
  // wireframe and random-color materials pull vertices and indices
  .VERTEX   = {.Vertex, .Storage, .CopyDst},
  .INDEX    = {.Index, .Storage, .CopyDst},
  .SKINNING = {.Storage, .CopyDst},
}

// table reads t from the frame render described.
@(private)
table :: #force_inline proc(desc: ^FrameDesc, t: Table, $T: typeid) -> []T {
  return ([^]T)(raw_data(desc.tables[t]))[:len(desc.tables[t]) / size_of(T)]
}

@(private)
tables_init :: proc(b: ^Backend, table_size: [Table]int, mesh_size: [MeshStream]int) {
  for &buffer, t in b.table_buffers {
    // a binding may not be empty
    buffer = buffer_create(b, max(table_size[t], 16), {.Storage, .CopyDst})
  }
  for &buffer, s in b.mesh_buffers do buffer = buffer_create(b, mesh_size[s], MESH_STREAM_USAGE[s])
}

// Uploads every region render wrote since the last frame; WriteBuffer takes 4-byte multiples.
@(private)
tables_upload :: proc(b: ^Backend, desc: ^FrameDesc) {
  for t in Table {
    dirty := desc.dirty[t]
    if dirty == 0 do continue
    src := desc.tables[t]
    size := (len(src) + TABLE_REGIONS - 1) / TABLE_REGIONS
    r := 0
    for r < TABLE_REGIONS {
      if dirty & (1 << u64(r)) == 0 {
        r += 1
        continue
      }
      first := r
      for r < TABLE_REGIONS && dirty & (1 << u64(r)) != 0 do r += 1
      lo := min(first * size, len(src)) &~ 3
      hi := min((min(r * size, len(src)) + 3) &~ 3, len(src))
      if hi > lo do wgpu.QueueWriteBuffer(b.queue, b.table_buffers[t], u64(lo), &src[lo], uint(hi - lo))
    }
  }
}

// mesh_write uploads data at element `first` of stream's buffer before the next frame.
mesh_write :: proc(b: ^Backend, stream: MeshStream, data: []$T, first: u32) -> bool {
  #assert(size_of(T) % 4 == 0)
  if len(data) == 0 do return true
  wgpu.QueueWriteBuffer(b.queue, b.mesh_buffers[stream], u64(first) * size_of(T), raw_data(data), uint(len(data) * size_of(T)))
  return true
}

@(private)
buffer_create :: proc(b: ^Backend, size: int, usage: wgpu.BufferUsageFlags) -> wgpu.Buffer {
  return wgpu.DeviceCreateBuffer(b.device, &{usage = usage, size = u64((size + 3) &~ 3)})
}
