package world

import cont "../containers"
import "../geometry"
import "../gpu"
import "../resources"
import "core:log"
import "core:math/linalg"
import vk "vendor:vulkan"

BakeInput :: struct {
  geometry:  geometry.Geometry,
  transform: matrix[4, 4]f32,
}

bake :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  inputs: []BakeInput,
) -> (
  mesh_handle: resources.MeshHandle,
  ret: vk.Result,
) {
  vertices := make([dynamic]geometry.Vertex, 0, 4096)
  indices := make([dynamic]u32, 0, 16384)
  for inp in inputs {
    vertex_base := u32(len(vertices))
    for v in inp.geometry.vertices {
      p :=
        inp.transform * [4]f32{v.position.x, v.position.y, v.position.z, 1.0}
      append(&vertices, geometry.Vertex{position = p.xyz})
    }
    for src_index in inp.geometry.indices {
      append(&indices, vertex_base + src_index)
    }
  }
  if len(vertices) == 0 {
    return {}, .ERROR_INITIALIZATION_FAILED
  }
  log.infof(
    "Baked %d vertices and %d indices from %d geometries",
    len(vertices),
    len(indices),
    len(inputs),
  )
  geom := geometry.Geometry {
    vertices = vertices[:],
    indices  = indices[:],
  }
  return resources.create_mesh(gctx, rm, geom)
}

bake_world :: proc(
  world: ^World,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  geometries: map[resources.MeshHandle]geometry.Geometry,
  include_filter: NodeTagSet = {.ENVIRONMENT},
  exclude_filter: NodeTagSet = {},
) -> (
  mesh_handle: resources.MeshHandle,
  ret: vk.Result,
) {
  inputs := make([dynamic]BakeInput, 0, 256)
  defer delete(inputs)
  for &entry in world.nodes.entries do if entry.active {
    node := &entry.item
    if !match_filter(node.tags, include_filter, exclude_filter) do continue
    mesh_attachment, is_mesh := node.attachment.(MeshAttachment)
    if !is_mesh do continue
    geom, has_geom := geometries[mesh_attachment.handle]
    if !has_geom do continue
    append(
      &inputs,
      BakeInput{geometry = geom, transform = node.transform.world_matrix},
    )
  }
  return bake(gctx, rm, inputs[:])
}

match_filter :: proc(
  tags: NodeTagSet,
  include: NodeTagSet,
  exclude: NodeTagSet,
) -> bool {
  if card(exclude) > 0 && (tags & exclude) != {} do return false
  if card(include) == 0 do return true
  return (tags & include) != {}
}
