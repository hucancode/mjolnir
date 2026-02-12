package world

import cont "../containers"
import "../geometry"
import "core:log"

load_obj :: proc(
  world: ^World,
  path: string,
  material: MaterialHandle,
  scale: f32 = 1.0,
  cast_shadow: bool = true,
) -> (
  nodes: [dynamic]NodeHandle,
  ok: bool,
) {
  // step 1: Load geometry from OBJ file
  geom := geometry.load_obj(path, scale) or_return
  log.infof("Loaded OBJ file: %s", path)
  log.infof(
    "  Vertices: %d, Triangles: %d",
    len(geom.vertices),
    len(geom.indices) / 3,
  )
  // step 2: Create mesh resource in CPU pools
  mesh_handle: MeshHandle
  mesh_ptr: ^Mesh
  mesh_handle, mesh_ptr, ok = create_mesh(world, geom, true)
  if !ok {
    log.errorf("Failed to create mesh from OBJ file: %s", path)
    return nodes, false
  }
  // Geometry upload is handled by engine/render staging sync.
  log.warn(
    "OBJ mesh created in CPU pools; geometry upload must be scheduled by engine",
  )
  stage_mesh_data(&world.staging, mesh_handle)
  log.infof("Created mesh %v", mesh_handle)
  // step 3: Create node with mesh attachment
  node_handle: NodeHandle
  node: ^Node
  node_handle, node = cont.alloc(&world.nodes, NodeHandle) or_return
  init_node(node, path)
  node.transform = geometry.TRANSFORM_IDENTITY
  node.attachment = MeshAttachment {
    handle      = mesh_handle,
    material    = material,
    cast_shadow = cast_shadow,
  }
  node.parent = world.root
  attach(world.nodes, world.root, node_handle)
  // Reference the mesh and material to prevent auto-purge
  append(&nodes, node_handle)
  log.infof("OBJ loading complete: 1 node created")
  return nodes, true
}
