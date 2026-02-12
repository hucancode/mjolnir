package world

import "core:slice"

register_active_light :: proc(world: ^World, node_handle: NodeHandle) {
  if slice.contains(world.active_light_nodes[:], node_handle) do return
  if len(world.active_light_nodes) >= MAX_LIGHTS do return
  append(&world.active_light_nodes, node_handle)
  stage_light_data(&world.staging, node_handle)
}

unregister_active_light :: proc(world: ^World, node_handle: NodeHandle) {
  if i, found := slice.linear_search(world.active_light_nodes[:], node_handle);
     found {
    unordered_remove(&world.active_light_nodes, i)
    for active_node_handle in world.active_light_nodes {
      stage_light_data(&world.staging, active_node_handle)
    }
  }
}
