package mjolnir

import "animation"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "geometry"
import "resource"

PointLightAttachment :: struct {
  color:       [4]f32,
  radius:      f32,
  cast_shadow: bool,
}

DirectionalLightAttachment :: struct {
  color:       [4]f32,
  cast_shadow: bool,
}

SpotLightAttachment :: struct {
  color:       [4]f32,
  radius:      f32,
  angle:       f32,
  cast_shadow: bool,
}

NodeSkinning :: struct {
  animation:          Maybe(animation.Instance),
  bone_matrix_offset: u32,
}

MeshAttachment :: struct {
  handle:      Handle,
  material:    Handle,
  skinning:    Maybe(NodeSkinning),
  cast_shadow: bool,
}

ParticleSystemAttachment :: struct {
  bounding_box:   geometry.Aabb,
  texture_handle: resource.Handle, // Handle to particle texture, zero for default
}

EmitterAttachment :: struct {
  initial_velocity:  [4]f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  emission_rate:     f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  size_start:        f32,
  size_end:          f32,
  enabled:           b32,
  weight:            f32,
  weight_spread:     f32,
  texture_handle:    resource.Handle,
  bounding_box:      geometry.Aabb,
}

ForceFieldAttachment :: struct {
  tangent_strength: f32, // 0 = push/pull in straight line, 1 = push/pull in tangent line
  strength:         f32, // positive = attract, negative = repel
  area_of_effect:   f32, // radius
  fade:             f32, // 0..1, linear fade factor
}

NodeAttachment :: union {
  PointLightAttachment,
  DirectionalLightAttachment,
  SpotLightAttachment,
  MeshAttachment,
  ParticleSystemAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
  NavMeshAttachment,
  NavMeshAgentAttachment,
  NavMeshObstacleAttachment,
}

Node :: struct {
  parent:          Handle,
  children:        [dynamic]Handle,
  transform:       geometry.Transform,
  name:            string,
  attachment:      NodeAttachment,
  culling_enabled: bool,
  visible:         bool,              // Node's own visibility state
  parent_visible:  bool,              // Visibility inherited from parent chain
  pending_deletion: bool, // Atomic flag for safe deletion
}

SceneTraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

init_node :: proc(self: ^Node, name: string = "") {
  self.children = make([dynamic]Handle, 0)
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.culling_enabled = true
  self.visible = true
  self.parent_visible = true
}

deinit_node :: proc(self: ^Node, warehouse: ^ResourceWarehouse) {
  delete(self.children)
  data, has_mesh := &self.attachment.(MeshAttachment)
  if !has_mesh {
    return
  }
  skinning, has_skin := &data.skinning.?
  if !has_skin || skinning.bone_matrix_offset == 0xFFFFFFFF {
    return
  }
  resource.slab_free(&warehouse.bone_matrix_slab, skinning.bone_matrix_offset)
  skinning.bone_matrix_offset = 0xFFFFFFFF
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
  parent_handle, child_handle: Handle,
) {
  child_node := resource.get(nodes, child_handle)
  parent_node := resource.get(nodes, parent_handle)
  if child_node == nil || parent_node == nil {
    return
  }
  if old_parent_node, ok := resource.get(nodes, child_node.parent); ok {
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
  mesh := resource.get(engine.warehouse.meshes, data.handle)
  skinning, has_skin := &data.skinning.?
  if mesh == nil || !has_skin {
    return false
  }
  anim_inst, found := make_animation_instance(mesh, name, mode)
  if !found {
    return false
  }
  skinning.animation = anim_inst
  return true
}

spawn_at :: proc(
  self: ^Scene,
  position: [3]f32,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&self.nodes)
  init_node(node)
  node.attachment = attachment
  geometry.translate(&node.transform, position.x, position.y, position.z)
  attach(self.nodes, self.root, handle)
  return
}

spawn :: proc(
  self: ^Scene,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&self.nodes)
  init_node(node)
  node.attachment = attachment
  attach(self.nodes, self.root, handle)
  return
}

spawn_child :: proc(
  self: ^Scene,
  parent: Handle,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&self.nodes)
  init_node(node)
  node.attachment = attachment
  attach(self.nodes, parent, handle)
  return
}

SceneTraverseEntry :: struct {
  handle:           Handle,
  parent_transform: matrix[4, 4]f32,
  parent_is_dirty:  bool,
  parent_is_visible: bool,
}

Scene :: struct {
  root:            Handle,
  nodes:           resource.Pool(Node),
  traversal_stack: [dynamic]SceneTraverseEntry,
}

scene_init :: proc(self: ^Scene) {
  // Camera is now owned by the main render target, not the scene
  // log.infof("Initializing nodes pool... ")
  resource.pool_init(&self.nodes)
  root: ^Node
  self.root, root = resource.alloc(&self.nodes)
  init_node(root, "root")
  root.parent = self.root
  self.traversal_stack = make([dynamic]SceneTraverseEntry, 0)
}

scene_deinit :: proc(self: ^Scene, warehouse: ^ResourceWarehouse) {
  for &entry in self.nodes.entries {
    if entry.active {
      deinit_node(&entry.item, warehouse)
    }
  }
  resource.pool_deinit(self.nodes, proc(node: ^Node) {})
  delete(self.traversal_stack)
}

// Camera mode switching is now handled by camera controllers
// switch_camera_mode_scene :: proc(self: ^Scene) {
//   // This function is no longer needed with the new camera controller system
// }

scene_traverse :: proc(
  self: ^Scene,
  cb_context: rawptr = nil,
  callback: SceneTraversalCallback = nil,
) -> bool {
  using geometry
  append(
    &self.traversal_stack,
    SceneTraverseEntry{self.root, linalg.MATRIX4F32_IDENTITY, false, true},
  )
  for len(self.traversal_stack) > 0 {
    entry := pop(&self.traversal_stack)
    current_node, found := resource.get(self.nodes, entry.handle)
    if !found {
      log.errorf(
        "traverse_scene: Node with handle %v not found\n",
        entry.handle,
      )
      continue
    }
    // Skip nodes that are pending deletion
    if current_node.pending_deletion do continue

    // Update parent_visible from parent chain only
    current_node.parent_visible = entry.parent_is_visible

    is_dirty := transform_update_local(&current_node.transform)
    if entry.parent_is_dirty || is_dirty {
      transform_update_world(&current_node.transform, entry.parent_transform)
    }
    // Only call the callback if the node is effectively visible
    if callback != nil && current_node.parent_visible && current_node.visible {
      if !callback(current_node, cb_context) do continue
    }
    // Copy children array to avoid race conditions during iteration
    children_copy := make([]Handle, len(current_node.children))
    defer delete(children_copy)
    copy(children_copy, current_node.children[:])
    for child_handle in children_copy {
      append(
        &self.traversal_stack,
        SceneTraverseEntry {
          child_handle,
          geometry.transform_get_world_matrix(&current_node.transform),
          is_dirty || entry.parent_is_dirty,
          current_node.parent_visible && current_node.visible, // Pass combined visibility to children
        },
      )
    }
  }
  return true
}

scene_traverse_linear :: proc(
  self: ^Scene,
  cb_context: rawptr,
  callback: SceneTraversalCallback,
) -> bool {
  for &entry in self.nodes.entries do if entry.active && entry.item.parent_visible && entry.item.visible && !entry.item.pending_deletion {
    callback(&entry.item, cb_context)
  }
  return true
}

// Safe despawn function that uses deferred cleanup
despawn :: proc(engine: ^Engine, handle: Handle) {
  // Mark node as pending deletion to prevent processing
  if node := resource.get(engine.scene.nodes, handle); node != nil {
    node.pending_deletion = true
    // Detach from parent first to prevent traversal issues
    detach(engine.scene.nodes, handle)
  }
  // Queue for deletion at end of frame
  queue_node_deletion(engine, handle)
}

// Safe spawn functions that ensure frame-boundary safety
safe_spawn :: proc(
  engine: ^Engine,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  return spawn(&engine.scene, attachment)
}

safe_spawn_at :: proc(
  engine: ^Engine,
  position: [3]f32,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  return spawn_at(&engine.scene, position, attachment)
}

safe_spawn_child :: proc(
  engine: ^Engine,
  parent: Handle,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  return spawn_child(&engine.scene, parent, attachment)
}
