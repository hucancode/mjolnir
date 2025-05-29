package mjolnir

import "animation"
import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import "core:slice"
import "geometry"
import "resource"

PointLightAttachment :: struct {
  color:       linalg.Vector4f32,
  radius:      f32,
  cast_shadow: bool,
}

DirectionalLightAttachment :: struct {
  color:       linalg.Vector4f32,
  cast_shadow: bool,
}

SpotLightAttachment :: struct {
  color:       linalg.Vector4f32,
  radius:      f32,
  angle:       f32,
  cast_shadow: bool,
}

MeshAttachment :: struct {
  handle:      Handle,
  bone_buffer: Maybe(DataBuffer),
  pose:        Maybe(animation.Pose),
  animation:   Maybe(animation.Instance),
  cast_shadow: bool,
}

NodeAttachment :: union {
  PointLightAttachment,
  DirectionalLightAttachment,
  SpotLightAttachment,
  MeshAttachment,
}

Node :: struct {
  parent:     Handle,
  children:   [dynamic]Handle,
  transform:  geometry.Transform,
  name:       string,
  attachment: NodeAttachment,
}

SceneTraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

init_node :: proc(node: ^Node, name_str: string = "") {
  node.children = make([dynamic]Handle, 0)
  node.transform = geometry.TRANSFORM_IDENTITY
  node.name = name_str
}

deinit_node :: proc(node: ^Node) {
  delete(node.children)
}

detach :: proc(nodes: resource.Pool(Node), child_handle: Handle) {
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
  nodes: resource.Pool(Node),
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
  node := resource.get(engine.scene.nodes, node_handle)
  if node == nil {
    return false
  }
  data, ok := &node.attachment.(MeshAttachment)
  if !ok {
    return false
  }
  mesh := resource.get(engine.meshes, data.handle)
  if mesh == nil {
    return false
  }
  anim_inst, found := make_animation_instance(mesh, name, mode)
  if !found {
    return false
  }
  data.animation = anim_inst
  return true
}

spawn_at :: proc(
  scene: ^Scene,
  position: linalg.Vector3f32,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&scene.nodes)
  if node != nil {
    init_node(node)
    node.attachment = attachment
    geometry.translate(&node.transform, position.x, position.y, position.z)
    attach(scene.nodes, scene.root, handle)
  }
  return
}

spawn :: proc(
  scene: ^Scene,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&scene.nodes)
  if node != nil {
    init_node(node)
    node.attachment = attachment
    attach(scene.nodes, scene.root, handle)
  }
  return
}

spawn_child :: proc(
  scene: ^Scene,
  parent: Handle,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&scene.nodes)
  if node != nil {
    init_node(node)
    node.attachment = attachment
    attach(scene.nodes, parent, handle)
  }
  return
}

Scene :: struct {
  camera: geometry.Camera,
  root:   Handle,
  nodes:  resource.Pool(Node),
}

init_scene :: proc(s: ^Scene) {
  s.camera = geometry.make_camera_orbit(
    math.PI * 0.5, // fov
    16.0 / 9.0, // aspect_ratio
    0.01, // near
    100.0, // far
  )
  fmt.print("Initializing nodes pool... ")
  resource.pool_init(&s.nodes)
  fmt.println("done")
  root: ^Node
  s.root, root = resource.alloc(&s.nodes)
  init_node(root, "root")
  root.parent = s.root
}

deinit_scene :: proc(s: ^Scene) {
  resource.pool_deinit(s.nodes, deinit_node)
}

switch_camera_mode_scene :: proc(s: ^Scene) {
  _, in_orbit_mode := s.camera.movement_data.(geometry.CameraOrbitMovement)
  if in_orbit_mode {
    geometry.camera_switch_to_free(&s.camera)
  } else {
    geometry.camera_switch_to_orbit(&s.camera, nil, nil)
  }
}

// TODO: make a new traverse procedure that does flat traversal and don't update transform matrix
traverse_scene :: proc(
  scene: ^Scene,
  cb_context: rawptr,
  callback: SceneTraversalCallback = nil,
) -> bool {
  using geometry
  node_stack := make([dynamic]Handle, 0)
  defer delete(node_stack)
  transform_stack := make([dynamic]linalg.Matrix4f32, 0)
  defer delete(transform_stack)
  dirty_stack := make([dynamic]bool, 0)
  defer delete(dirty_stack)

  append(&node_stack, scene.root)
  append(&transform_stack, linalg.MATRIX4F32_IDENTITY)
  append(&dirty_stack, false)

  for len(node_stack) > 0 {
    current_node_handle := pop(&node_stack)
    parent_world_matrix := pop(&transform_stack)
    parent_is_dirty := pop(&dirty_stack)
    current_node := resource.get(scene.nodes, current_node_handle)
    if current_node == nil {
      fmt.eprintf(
        "traverse_scene: Node with handle %v not found\n",
        current_node_handle,
      )
      continue
    }
    is_dirty := transform_update_local(&current_node.transform)
    if parent_is_dirty || is_dirty {
      transform_update_world(&current_node.transform, parent_world_matrix)
    }
    if callback != nil {
      if !callback(current_node, cb_context) {
        continue
      }
    }
    for child_handle in current_node.children {
      append(&node_stack, child_handle)
      append(&transform_stack, current_node.transform.world_matrix)
      append(&dirty_stack, is_dirty || parent_is_dirty)
    }
  }
  return true
}
