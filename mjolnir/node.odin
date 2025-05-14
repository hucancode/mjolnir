package mjolnir

import "base:runtime"
import "core:math"
import linalg "core:math/linalg"
import "geometry"
import "resource"

NodeSkeletalMeshAttachment :: struct {
  handle:    Handle,
  pose:      Pose,
  animation: Maybe(Animation_Instance),
}
NodeStaticMeshAttachment :: struct {
  handle: Handle,
}
NodeLightAttachment :: struct {
  handle: Handle,
}

Node :: struct {
  parent:     Handle,
  children:   [dynamic]Handle,
  transform:  geometry.Transform,
  name:       string,
  attachment: union {
    NodeLightAttachment,
    NodeStaticMeshAttachment,
    NodeSkeletalMeshAttachment,
  },
}

init_node :: proc(node: ^Node, name_str: string) {
  node.children = make([dynamic]Handle, 0)
  node.transform = geometry.transform_identity()
  node.name = name_str
  node.attachment = nil
  node.parent = Handle{}
}

deinit_node :: proc(node: ^Node) {
  delete(node.children)
}

unparent_node :: proc(
  nodes: ^resource.ResourcePool(Node),
  child_handle: Handle,
) {
  child_node := resource.get(nodes, child_handle)
  if child_node == nil {
    return
  }
  parent_handle := child_node.parent
  if parent_handle == (Handle{}) || parent_handle == child_handle {
    return
  }
  parent_node := resource.get(nodes, parent_handle)
  if parent_node == nil {
    return
  }

  found_idx := -1
  for child_in_parent_list, i in parent_node.children {
    if child_in_parent_list == child_handle {
      found_idx = i
      break
    }
  }

  if found_idx != -1 {
    ordered_remove(&parent_node.children, found_idx)
  }

  child_node.parent = Handle{}
}

parent_node :: proc(
  nodes: ^resource.ResourcePool(Node),
  parent_handle: Handle,
  child_handle: Handle,
) {
  if parent_handle == child_handle {return}

  child_node := resource.get(nodes, child_handle)
  parent_node := resource.get(nodes, parent_handle)

  if child_node == nil || parent_node == nil {
    return
  }

  unparent_node(nodes, child_handle)

  child_node.parent = parent_handle
  append(&parent_node.children, child_handle)
}
