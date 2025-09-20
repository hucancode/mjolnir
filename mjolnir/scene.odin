package mjolnir

import "animation"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "geometry"
import "gpu"
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
  node_id:     u32,  // Node ID for indirect drawing - populated when node is created
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
  parent:            Handle,
  children:          [dynamic]Handle,
  transform:         geometry.Transform,
  name:              string,
  attachment:        NodeAttachment,
  animation:         Maybe(animation.Instance), // For node transform animation
  culling_enabled:   bool,
  visible:           bool,              // Node's own visibility state
  parent_visible:    bool,              // Visibility inherited from parent chain
  pending_deletion:  bool, // Atomic flag for safe deletion
  is_world_dirty:    bool, // World matrix needs to be updated in GPU buffer
}

SceneTraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

init_node :: proc(self: ^Node, warehouse: ^ResourceWarehouse, name: string = "", handle: Handle = {}) {
  self.children = make([dynamic]Handle, 0)
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.culling_enabled = true
  self.visible = true
  self.parent_visible = true
  self.is_world_dirty = true

  // Initialize world matrix in both frame buffers for new nodes
  if handle.index != 0 {
    world_matrix := get_world_matrix(self)
    init_world_matrix(warehouse, handle.index, &world_matrix)
  }
}

// Populate NodeData for a mesh attachment after it's created
populate_node_data :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
  mesh_attachment: ^MeshAttachment,
) {
  // Store node_id in mesh attachment for later use
  mesh_attachment.node_id = handle.index

  // Get mesh to find mesh_id and material_id
  mesh := resource.get(warehouse.meshes, mesh_attachment.handle)
  if mesh == nil {
    log.errorf("Failed to get mesh for node %d", handle.index)
    return
  }

  // Check bounds before accessing NodeData
  if handle.index >= warehouse.max_nodes {
    log.errorf("Node ID %d exceeds max nodes %d", handle.index, warehouse.max_nodes)
    return
  }

  // Populate NodeData
  node_data := &warehouse.node_data[handle.index]
  node_data.material_id = mesh_attachment.material.index
  node_data.mesh_id = mesh_attachment.handle.index

  if skinning, has_skinning := mesh_attachment.skinning.?; has_skinning {
    node_data.bone_matrix_offset = skinning.bone_matrix_offset
  }

  // Upload to GPU
  gpu.data_buffer_write_single(&warehouse.node_data_buffer, node_data, int(handle.index))

  log.debugf("Populated NodeData for node %d: material_id=%d, mesh_id=%d, bone_offset=%d",
    handle.index, node_data.material_id, node_data.mesh_id, node_data.bone_matrix_offset)
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
  mesh := mesh(engine, data.handle)
  skinning, has_skin := &data.skinning.?
  if mesh == nil || !has_skin {
    return false
  }
  anim_inst, found := make_animation_instance(&engine.warehouse, name, mode)
  if !found {
    return false
  }
  skinning.animation = anim_inst
  return true
}

spawn_at :: proc(
  self: ^Scene,
  warehouse: ^ResourceWarehouse,
  position: [3]f32,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&self.nodes)
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
  init_node(node, warehouse, "", handle)
  node.attachment = attachment
  // Populate node data for mesh attachments
  if mesh_attachment, is_mesh := &node.attachment.(MeshAttachment); is_mesh {
    populate_node_data(warehouse, handle, mesh_attachment)
  }
  attach(self.nodes, self.root, handle)
  return
}

spawn :: proc(
  self: ^Scene,
  warehouse: ^ResourceWarehouse,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&self.nodes)
  init_node(node, warehouse, "", handle)
  node.attachment = attachment
  // Populate node data for mesh attachments
  if mesh_attachment, is_mesh := &node.attachment.(MeshAttachment); is_mesh {
    populate_node_data(warehouse, handle, mesh_attachment)
  }
  attach(self.nodes, self.root, handle)
  return
}

spawn_child :: proc(
  self: ^Scene,
  warehouse: ^ResourceWarehouse,
  parent: Handle,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&self.nodes)
  init_node(node, warehouse, "", handle)
  node.attachment = attachment
  // Populate node data for mesh attachments
  if mesh_attachment, is_mesh := &node.attachment.(MeshAttachment); is_mesh {
    populate_node_data(warehouse, handle, mesh_attachment)
  }
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

scene_init :: proc(self: ^Scene, warehouse: ^ResourceWarehouse) {
  // Camera is now owned by the main render target, not the scene
  // log.infof("Initializing nodes pool... ")
  resource.pool_init(&self.nodes)
  root: ^Node
  self.root, root = resource.alloc(&self.nodes)
  init_node(root, warehouse, "root", self.root)
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
      current_node.is_world_dirty = true
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
          get_world_matrix(current_node),
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

// Node transform manipulation functions
node_translate_by :: proc(node: ^Node, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  geometry.transform_translate_by(&node.transform, x, y, z)
}

node_translate :: proc(node: ^Node, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  geometry.transform_translate(&node.transform, x, y, z)
}

node_rotate_by :: proc {
  node_rotate_by_quaternion,
  node_rotate_by_angle,
}

node_rotate_by_quaternion :: proc(node: ^Node, q: quaternion128) {
  geometry.transform_rotate_by_quaternion(&node.transform, q)
}

node_rotate_by_angle :: proc(
  node: ^Node,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  geometry.transform_rotate_by_angle(&node.transform, angle, axis)
}

node_rotate :: proc {
  node_rotate_quaternion,
  node_rotate_angle,
}

node_rotate_quaternion :: proc(node: ^Node, q: quaternion128) {
  geometry.transform_rotate_quaternion(&node.transform, q)
}

node_rotate_angle :: proc(
  node: ^Node,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  geometry.transform_rotate_angle(&node.transform, angle, axis)
}

node_scale_xyz_by :: proc(node: ^Node, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  geometry.transform_scale_xyz_by(&node.transform, x, y, z)
}

node_scale_by :: proc(node: ^Node, s: f32) {
  geometry.transform_scale_by(&node.transform, s)
}

node_scale_xyz :: proc(node: ^Node, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  geometry.transform_scale_xyz(&node.transform, x, y, z)
}

node_scale :: proc(node: ^Node, s: f32) {
  geometry.transform_scale(&node.transform, s)
}

// Node handle transform manipulation functions
node_handle_translate_by :: proc(scene: ^Scene, handle: Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_translate_by(&node.transform, x, y, z)
  }
}

node_handle_translate :: proc(scene: ^Scene, handle: Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_translate(&node.transform, x, y, z)
  }
}

node_handle_rotate_by :: proc {
  node_handle_rotate_by_quaternion,
  node_handle_rotate_by_angle,
}

node_handle_rotate_by_quaternion :: proc(scene: ^Scene, handle: Handle, q: quaternion128) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_rotate_by_quaternion(&node.transform, q)
  }
}

node_handle_rotate_by_angle :: proc(
  scene: ^Scene,
  handle: Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_rotate_by_angle(&node.transform, angle, axis)
  }
}

node_handle_rotate :: proc {
  node_handle_rotate_quaternion,
  node_handle_rotate_angle,
}

node_handle_rotate_quaternion :: proc(scene: ^Scene, handle: Handle, q: quaternion128) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_rotate_quaternion(&node.transform, q)
  }
}

node_handle_rotate_angle :: proc(
  scene: ^Scene,
  handle: Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_rotate_angle(&node.transform, angle, axis)
  }
}

node_handle_scale_xyz_by :: proc(scene: ^Scene, handle: Handle, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_scale_xyz_by(&node.transform, x, y, z)
  }
}

node_handle_scale_by :: proc(scene: ^Scene, handle: Handle, s: f32) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_scale_by(&node.transform, s)
  }
}

node_handle_scale_xyz :: proc(scene: ^Scene, handle: Handle, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_scale_xyz(&node.transform, x, y, z)
  }
}

node_handle_scale :: proc(scene: ^Scene, handle: Handle, s: f32) {
  if node := resource.get(scene.nodes, handle); node != nil {
    geometry.transform_scale(&node.transform, s)
  }
}

// Overloaded procedure groups that work with Transform, Node pointers, and Node handles
translate_by :: proc {
  geometry.transform_translate_by,
  node_translate_by,
  node_handle_translate_by,
}

translate :: proc {
  geometry.transform_translate,
  node_translate,
  node_handle_translate,
}

rotate_by :: proc {
  geometry.transform_rotate_by_quaternion,
  geometry.transform_rotate_by_angle,
  node_rotate_by_quaternion,
  node_rotate_by_angle,
  node_handle_rotate_by_quaternion,
  node_handle_rotate_by_angle,
}

rotate :: proc {
  geometry.transform_rotate_quaternion,
  geometry.transform_rotate_angle,
  node_rotate_quaternion,
  node_rotate_angle,
  node_handle_rotate_quaternion,
  node_handle_rotate_angle,
}

scale_xyz_by :: proc {
  geometry.transform_scale_xyz_by,
  node_scale_xyz_by,
  node_handle_scale_xyz_by,
}

scale_by :: proc {
  geometry.transform_scale_by,
  node_scale_by,
  node_handle_scale_by,
}

scale_xyz :: proc {
  geometry.transform_scale_xyz,
  node_scale_xyz,
  node_handle_scale_xyz,
}

scale :: proc {
  geometry.transform_scale,
  node_scale,
  node_handle_scale,
}

despawn :: proc(engine: ^Engine, handle: Handle) {
  if node := resource.get(engine.scene.nodes, handle); node != nil {
    node.pending_deletion = true
    detach(engine.scene.nodes, handle)
  }
  queue_node_deletion(engine, handle)
}

node_get_world_matrix :: proc(node: ^Node) -> matrix[4,4]f32 {
    return geometry.transform_get_world_matrix(&node.transform)
}

node_get_world_matrix_for_render :: proc(node: ^Node) -> matrix[4,4]f32 {
  return geometry.transform_get_world_matrix_for_render(&node.transform)
}

get_world_matrix :: proc {
    node_get_world_matrix,
    geometry.transform_get_world_matrix,
}

get_world_matrix_for_render :: proc {
    node_get_world_matrix_for_render,
    geometry.transform_get_world_matrix_for_render,
}

// Update all dirty world matrices in the specified frame buffer
update_dirty_world_matrices :: proc(scene: ^Scene, warehouse: ^ResourceWarehouse, frame_index: u32) {
  for &entry, i in scene.nodes.entries do if entry.active && entry.item.is_world_dirty {
    node := &entry.item
    world_matrix := get_world_matrix(node)
    handle_index := u32(i)

    // Write to the frame buffer for this frame index
    update_world_matrix(warehouse, frame_index, handle_index, &world_matrix)

    node.is_world_dirty = false

    // Debug: Log matrix updates for verification
    if handle_index < 10 || handle_index > 800 {
      log.debugf("Matrix update: node=%d, frame_index=%d, pos=(%.2f,%.2f,%.2f)",
        handle_index, frame_index,
        world_matrix[3][0], world_matrix[3][1], world_matrix[3][2])
    }
  }
}
