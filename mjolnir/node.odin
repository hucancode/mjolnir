package mjolnir

import "animation"
import linalg "core:math/linalg"
import "core:slice"
import "geometry"
import "resource"

NodeSkeletalMeshAttachment :: struct {
  handle:      Handle,
  bone_buffer: DataBuffer,
  pose:        animation.Pose,
  animation:   Maybe(animation.Instance),
  cast_shadow: bool,
}

NodeStaticMeshAttachment :: struct {
  handle:      Handle,
  cast_shadow: bool,
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
  node.transform = geometry.TRANSFORM_IDENTITY
  node.name = name_str
  node.attachment = nil
  node.parent = Handle{}
}

deinit_node :: proc(node: ^Node) {
  delete(node.children)
}

detach :: proc(nodes: ^resource.Pool(Node), child_handle: Handle) {
  child_node := resource.get(nodes, child_handle)
  if child_node == nil {
    return
  }
  parent_handle := child_node.parent
  if parent_handle == child_handle {
    return
  }
  parent_node := resource.get(nodes, parent_handle)
  if parent_node == nil {
    return
  }
  idx, found := slice.linear_search(parent_node.children[:], child_handle)
  if found {
    unordered_remove(&parent_node.children, idx)
  }
  child_node.parent = child_handle
}

attach :: proc(
  nodes: ^resource.Pool(Node),
  parent_handle: Handle,
  child_handle: Handle,
) {
  child_node := resource.get(nodes, child_handle)
  parent_node := resource.get(nodes, parent_handle)
  if child_node == nil || parent_node == nil {
    return
  }
  old_parent_node := resource.get(nodes, child_node.parent)
  if old_parent_node != nil {
    idx, found := slice.linear_search(
      old_parent_node.children[:],
      child_handle,
    )
    if found {
      unordered_remove(&old_parent_node.children, idx)
    }
  }
  child_node.parent = parent_handle
  if parent_handle != child_handle {
    append(&parent_node.children, child_handle)
  }
}

play_animation :: proc(
  engine: ^Engine,
  node_handle: Handle,
  name: string,
  mode: animation.PlayMode = .LOOP,
) -> bool {
  node := resource.get(&engine.nodes, node_handle)
  if node == nil {
    return false
  }
  data, ok := &node.attachment.(NodeSkeletalMeshAttachment)
  if !ok {
    return false
  }
  skeletal_mesh_res := resource.get(&engine.skeletal_meshes, data.handle)
  if skeletal_mesh_res == nil {
    return false
  }
  anim_inst, found := make_animation_instance(skeletal_mesh_res, name, mode)
  if !found {
    return false
  }
  data.animation = anim_inst
  return true
}

spawn_point_light :: proc(
  engine: ^Engine,
  color: linalg.Vector4f32,
  radius: f32,
  cast_shadow: bool = true,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = spawn(engine)
  if node != nil {
    light_handle, light := resource.alloc(&engine.lights)
    light^ = PointLight {
      color       = color,
      radius      = radius,
      cast_shadow = cast_shadow,
    }
    node.attachment = NodeLightAttachment{light_handle}
  }
  return
}

spawn_directional_light :: proc(
  engine: ^Engine,
  color: linalg.Vector4f32,
  cast_shadow: bool = true,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = spawn(engine)
  if node != nil {
    light_handle, light := resource.alloc(&engine.lights)
    light^ = DirectionalLight {
      color       = color,
      cast_shadow = cast_shadow,
    }
    node.attachment = NodeLightAttachment{light_handle}
  }
  return
}

spawn_spot_light :: proc(
  engine: ^Engine,
  color: linalg.Vector4f32,
  angle: f32,
  radius: f32,
  cast_shadow: bool = true,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = spawn(engine)
  if node != nil {
    light_handle, light := resource.alloc(&engine.lights)
    light^ = SpotLight {
      color       = color,
      angle       = angle,
      radius      = radius,
      cast_shadow = cast_shadow,
    }
    node.attachment = NodeLightAttachment{light_handle}
  }
  return
}

spawn :: proc(engine: ^Engine) -> (handle: Handle, node: ^Node) {
  handle, node = resource.alloc(&engine.nodes)
  if node != nil {
    node.transform = geometry.TRANSFORM_IDENTITY
    node.children = make([dynamic]Handle, 0)
    attach(&engine.nodes, engine.scene.root, handle)
  }
  return
}
