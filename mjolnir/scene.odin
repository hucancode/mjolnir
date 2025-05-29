package mjolnir

import "core:fmt"
import "core:math"
import "core:slice"
import linalg "core:math/linalg"
import "resource"
import "geometry"
import "animation"

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
Scene :: struct {
  camera: geometry.Camera,
  root:   Handle,
}

init_scene :: proc(s: ^Scene) {
  s.camera = geometry.camera_init_orbit(
    math.PI * 0.5, // fov
    16.0 / 9.0, // aspect_ratio
    0.01, // near
    100.0, // far
  )
}

deinit_scene :: proc(s: ^Scene) {
}


switch_camera_mode_scene :: proc(s: ^Scene) {
  _, in_orbit_mode := s.camera.movement_data.(geometry.CameraOrbitMovement)
  if in_orbit_mode {
    geometry.camera_switch_to_free(&s.camera)
  } else {
    geometry.camera_switch_to_orbit(&s.camera, nil, nil)
  }
}

traverse_scene :: proc(
  scene: ^Scene,
  nodes: ^resource.Pool(Node),
  cb_context: rawptr,
  callback: proc(
    node: ^Node,
    world_matrix: ^linalg.Matrix4f32,
    cb_context: rawptr,
  ) -> bool,
) -> bool {
  node_stack := make([dynamic]Handle, 0)
  defer delete(node_stack)
  transform_stack := make([dynamic]linalg.Matrix4f32, 0)
  defer delete(transform_stack)

  append(&node_stack, scene.root)
  append(&transform_stack, linalg.MATRIX4F32_IDENTITY)

  for len(node_stack) > 0 {
    current_node_handle := pop(&node_stack)
    parent_world_matrix := pop(&transform_stack)

    current_node := resource.get(nodes, current_node_handle)
    if current_node == nil {
      fmt.eprintf(
        "traverse_scene: Node with handle %v not found\n",
        current_node_handle,
      )
      continue
    }

    // TODO: instead of DFS and update transform matrix on render, we should transform on object request
    // Ensure transform is up-to-date (local_matrix from TRS)
    if current_node.transform.is_dirty {
      current_node.transform.local_matrix = linalg.matrix4_from_trs(
        current_node.transform.position,
        current_node.transform.rotation,
        current_node.transform.scale,
      )
      // current_node.transform.is_dirty = false; // World matrix update will clear it if needed
    }
    current_node.transform.world_matrix =
      parent_world_matrix * current_node.transform.local_matrix
    current_node.transform.is_dirty = false

    if !callback(
      current_node,
      &current_node.transform.world_matrix,
      cb_context,
    ) {
      continue
    }

    for child_handle in current_node.children {
      append(&node_stack, child_handle)
      append(&transform_stack, current_node.transform.world_matrix)
    }
  }
  return true
}
