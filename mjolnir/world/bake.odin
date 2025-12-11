package world

import cont "../containers"
import "../geometry"
import "../gpu"
import "../resources"
import "core:log"
import "core:math/linalg"
import vk "vendor:vulkan"

BakedNodeInfo :: struct {
  tags:         NodeTagSet,
  vertex_count: int,
  index_count:  int,
}

bake :: proc(
  world: ^World,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  include_filter: NodeTagSet = {.ENVIRONMENT},
  exclude_filter: NodeTagSet = {},
) -> (
  mesh_handle: resources.MeshHandle,
  ret: vk.Result,
) {
  geom, _ := bake_geometry(
    world,
    gctx,
    rm,
    include_filter,
    exclude_filter,
  ) or_return
  return resources.create_mesh(gctx, rm, geom)
}

bake_geometry :: proc(
  world: ^World,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  include_filter: NodeTagSet = {.ENVIRONMENT},
  exclude_filter: NodeTagSet = {},
  with_node_info: bool = false,
) -> (
  geom: geometry.Geometry,
  node_info: []BakedNodeInfo,
  ret: vk.Result,
) {
  match_filter :: proc(
    tags: NodeTagSet,
    include: NodeTagSet,
    exclude: NodeTagSet,
  ) -> bool {
    return(
      (exclude == {} || (tags & exclude) == {}) &&
      (include == {} || (tags & include) != {}) \
    )
  }
  vertices := make([dynamic]geometry.Vertex, 0, 4096)
  defer if ret != .SUCCESS do delete(vertices)
  indices := make([dynamic]u32, 0, 16384)
  defer if ret != .SUCCESS do delete(indices)
  nodes_info := make([dynamic]BakedNodeInfo, 0, 64) if with_node_info else nil
  defer if ret != .SUCCESS && with_node_info do delete(nodes_info)
  // Track which meshes we've already read to avoid duplicate reads
  read_meshes := make(map[resources.MeshHandle]geometry.Geometry)
  defer {
    for _, geom in read_meshes {
      delete(geom.vertices)
      delete(geom.indices)
    }
    delete(read_meshes)
  }
  mesh_count := 0
  for &entry in world.nodes.entries do if entry.active {
    node := &entry.item
    if !match_filter(node.tags, include_filter, exclude_filter) do continue
    mesh_attachment, is_mesh := node.attachment.(MeshAttachment)
    if !is_mesh do continue
    // Get or read the mesh geometry
    geom: geometry.Geometry
    if cached_geom, already_read := read_meshes[mesh_attachment.handle]; already_read {
      geom = cached_geom
    } else {
      mesh := cont.get(rm.meshes, mesh_attachment.handle) or_continue
      vertex_count := int(mesh.vertex_allocation.count)
      mesh_vertices := make([]geometry.Vertex, vertex_count)
      read_result := gpu.get_all(gctx, &rm.vertex_buffer, mesh_vertices, int(mesh.vertex_allocation.offset))
      if read_result != .SUCCESS {
        log.errorf("Failed to read vertex data for mesh %v", mesh_attachment.handle)
        delete(mesh_vertices)
        continue
      }
      index_count := int(mesh.index_allocation.count)
      mesh_indices := make([]u32, index_count)
      read_result = gpu.get_all(gctx, &rm.index_buffer, mesh_indices, int(mesh.index_allocation.offset))
      if read_result != .SUCCESS {
        log.errorf("Failed to read index data for mesh %v", mesh_attachment.handle)
        delete(mesh_vertices)
        delete(mesh_indices)
        continue
      }
      geom = geometry.Geometry {
        vertices = mesh_vertices,
        indices  = mesh_indices,
      }
      read_meshes[mesh_attachment.handle] = geom
    }
    vertex_base := u32(len(vertices))
    for v in geom.vertices {
      p := node.transform.world_matrix * [4]f32{v.position.x, v.position.y, v.position.z, 1.0}
      append(&vertices, geometry.Vertex{position = p.xyz})
    }
    for src_index in geom.indices {
      append(&indices, vertex_base + src_index)
    }
    // Track node info if requested
    if with_node_info {
      append(&nodes_info, BakedNodeInfo{
        tags = node.tags,
        vertex_count = len(geom.vertices),
        index_count = len(geom.indices),
      })
    }
    mesh_count += 1
  }
  if len(vertices) == 0 {
    return {}, nil, .ERROR_INITIALIZATION_FAILED
  }
  log.infof(
    "Baked %d vertices and %d indices from %d meshes",
    len(vertices),
    len(indices),
    mesh_count,
  )
  geom = geometry.Geometry {
    vertices = vertices[:],
    indices  = indices[:],
  }
  node_info = nodes_info[:]
  return
}
