package world

import cont "../containers"
import "../geometry"
import "../gpu"
import "../resources"
import "core:log"
import vk "vendor:vulkan"

load_obj :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  path: string,
  material: resources.MaterialHandle,
  scale: f32 = 1.0,
  cast_shadow: bool = true,
) -> (
  nodes: [dynamic]resources.NodeHandle,
  ok: bool,
) {
  // step 1: Load geometry from OBJ file
  geom := geometry.load_obj(path, scale) or_return
  log.infof("Loaded OBJ file: %s", path)
  log.infof("  Vertices: %d, Triangles: %d", len(geom.vertices), len(geom.indices) / 3)
  // step 2: Create mesh resource
  mesh_handle, result := resources.create_mesh(gctx, rm, geom, true)
  if result != .SUCCESS {
    log.errorf("Failed to create mesh from OBJ file: %s", path)
    return nodes, false
  }
  log.infof("Created mesh %v", mesh_handle)
  // step 3: Create node with mesh attachment
  node_handle: resources.NodeHandle
  node: ^Node
  node_handle, node = cont.alloc(&world.nodes, resources.NodeHandle) or_return
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
  resources.mesh_ref(rm, mesh_handle)
  resources.material_ref(rm, material)
  append(&nodes, node_handle)
  log.infof("OBJ loading complete: 1 node created")
  return nodes, true
}
