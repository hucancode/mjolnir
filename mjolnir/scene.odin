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
}

EmitterAttachment :: struct {
  handle: Handle,
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
  EmitterAttachment,
  ForceFieldAttachment,
  NavMeshAttachment,
  NavMeshAgentAttachment,
  NavMeshObstacleAttachment,
}

NodeFlag :: enum u32 {
  VISIBLE,
  CULLING_ENABLED,
  MATERIAL_TRANSPARENT,
  MATERIAL_WIREFRAME,
  CASTS_SHADOW,
}

NodeFlagSet :: bit_set[NodeFlag; u32]

NodeData :: struct {
  material_id:        u32,
  mesh_id:            u32,
  bone_matrix_offset: u32,
  flags:              NodeFlagSet,
}

Node :: struct {
  parent:          Handle,
  children:        [dynamic]Handle,
  transform:       geometry.Transform,
  name:            string,
  attachment:      NodeAttachment,
  animation:       Maybe(animation.Instance), // For node transform animation
  culling_enabled: bool,
  visible:         bool,              // Node's own visibility state
  parent_visible:  bool,              // Visibility inherited from parent chain
  pending_deletion: bool, // Atomic flag for safe deletion
}

SceneTraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

SceneEmitterState :: struct {
  slot_lookup: map[u32]u32,
  slot_nodes:  [MAX_EMITTERS]u32,
  slot_active: [MAX_EMITTERS]bool,
  slot_dirty:  [MAX_EMITTERS]bool,
  active_count: u32,
}

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
  if emitter_attachment, is_emitter := &self.attachment.(EmitterAttachment); is_emitter {
    if destroy_emitter_handle(warehouse, emitter_attachment.handle) {
      emitter_attachment.handle = {}
    }
  }
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
  position: [3]f32,
  attachment: NodeAttachment = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resource.alloc(&self.nodes)
  init_node(node)
  node.attachment = attachment
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
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
  emitters:        SceneEmitterState,
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
  self.emitters.slot_lookup = make(map[u32]u32)
  self.emitters.active_count = 0
  for i in 0 ..< MAX_EMITTERS {
    self.emitters.slot_nodes[i] = 0xFFFFFFFF
    self.emitters.slot_active[i] = false
    self.emitters.slot_dirty[i] = false
  }
}

scene_deinit :: proc(self: ^Scene, warehouse: ^ResourceWarehouse) {
  for &entry in self.nodes.entries {
    if entry.active {
      deinit_node(&entry.item, warehouse)
    }
  }
  delete(self.emitters.slot_lookup)
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

scene_emitters_sync :: proc(
  self: ^Scene,
  warehouse: ^ResourceWarehouse,
  emitters: []EmitterData,
  params: ^ParticleSystemParams,
) {
  state := &self.emitters
  previous_count := state.active_count
  for i in 0 ..< int(previous_count) do state.slot_active[i] = false

  active_count := state.active_count

  for &entry, index in self.nodes.entries do if entry.active {
    attachment, is_emitter := &entry.item.attachment.(EmitterAttachment)
    if !is_emitter do continue

    emitter_handle := attachment.handle
    emitter, has_emitter := resource.get(warehouse.emitters, emitter_handle)

    node_index := u32(index)
    slot, has_slot := state.slot_lookup[node_index]
    if has_slot {
      slot_idx := int(slot)
      if slot_idx >= len(state.slot_nodes) || slot_idx >= int(state.active_count) || state.slot_nodes[slot_idx] != node_index {
        has_slot = false
      }
    }

    if !has_emitter {
      if has_slot {
        state.slot_active[int(slot)] = false
        state.slot_dirty[int(slot)] = true
      }
      continue
    }

    enabled := emitter.enabled != b32(false)

    if !enabled || entry.item.pending_deletion {
      if has_slot {
        state.slot_active[int(slot)] = false
        state.slot_dirty[int(slot)] = true
      }
      continue
    }

    if !has_slot {
      if active_count >= MAX_EMITTERS {
        log.warnf("Emitter capacity reached (%d), skipping node %d", MAX_EMITTERS, node_index)
        continue
      }
      slot = active_count
      active_count += 1
      state.slot_lookup[node_index] = slot
      state.slot_dirty[int(slot)] = true
    }

    slot_idx := int(slot)
    state.slot_active[slot_idx] = true
    state.slot_nodes[slot_idx] = node_index

    if emitter.dirty {
      state.slot_dirty[slot_idx] = true
    }

    if state.slot_dirty[slot_idx] {
      gpu_emitter := &emitters[slot_idx]
      preserved_time := gpu_emitter.time_accumulator
      gpu_emitter^ = EmitterData {
        initial_velocity = emitter.initial_velocity,
        color_start = emitter.color_start,
        color_end = emitter.color_end,
        emission_rate = emitter.emission_rate,
        particle_lifetime = emitter.particle_lifetime,
        position_spread = emitter.position_spread,
        velocity_spread = emitter.velocity_spread,
        time_accumulator = preserved_time,
        size_start = emitter.size_start,
        size_end = emitter.size_end,
        weight = emitter.weight,
        weight_spread = emitter.weight_spread,
        texture_index = emitter.texture_handle.index,
        node_index = node_index,
        visible = b32(entry.item.parent_visible && entry.item.visible),
        aabb_min = {
          emitter.bounding_box.min.x,
          emitter.bounding_box.min.y,
          emitter.bounding_box.min.z,
          0.0,
        },
        aabb_max = {
          emitter.bounding_box.max.x,
          emitter.bounding_box.max.y,
          emitter.bounding_box.max.z,
          0.0,
        },
      }
      state.slot_dirty[slot_idx] = false
      emitter.dirty = false
    }
  }

  new_count: u32 = 0
  for slot_idx: u32 = 0; slot_idx < active_count; slot_idx += 1 {
    slot := int(slot_idx)
    if state.slot_active[slot] {
      if slot_idx != new_count {
        emitters[int(new_count)] = emitters[slot]
        node_idx := state.slot_nodes[slot]
        state.slot_nodes[int(new_count)] = node_idx
        state.slot_lookup[node_idx] = new_count
        state.slot_dirty[int(new_count)] = state.slot_dirty[slot]
        state.slot_active[int(new_count)] = true
      }
      new_count += 1
    } else {
      node_idx := state.slot_nodes[slot]
      state.slot_nodes[slot] = 0xFFFFFFFF
      state.slot_dirty[slot] = false
      state.slot_active[slot] = false
      emitters[slot].visible = cast(b32)false
    }
  }

  for i := int(new_count); i < int(active_count); i += 1 {
    state.slot_active[i] = false
  }

  state.active_count = new_count
  params.emitter_count = new_count
}

scene_mark_emitter_dirty :: proc(
  self: ^Scene,
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) {
  node := resource.get(self.nodes, handle)
  if node == nil {
    return
  }
  attachment, is_emitter := &node.attachment.(EmitterAttachment)
  if !is_emitter {
    return
  }
  emitter, ok := resource.get(warehouse.emitters, attachment.handle)
  if ok {
    emitter.dirty = true
  }
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

get_world_matrix :: proc {
    node_get_world_matrix,
    geometry.transform_get_world_matrix,
}

upload_world_matrices :: proc(
  warehouse: ^ResourceWarehouse,
  scene: ^Scene,
  frame_index: u32,
) {
  if frame_index >= MAX_FRAMES_IN_FLIGHT {
    return
  }
  matrices := gpu.data_buffer_get_all(&warehouse.world_matrix_buffers[frame_index])
  node_datas := gpu.data_buffer_get_all(&warehouse.node_data_buffer)
  if len(matrices) == 0 {
    return
  }
  identity := linalg.MATRIX4F32_IDENTITY
  for i in 0 ..< len(matrices) {
    matrices[i] = identity
  }
  default_node := NodeData {
    material_id        = 0xFFFFFFFF,
    mesh_id            = 0xFFFFFFFF,
    bone_matrix_offset = 0xFFFFFFFF,
    flags              = {},
  }
  for i in 0 ..< len(node_datas) {
    node_datas[i] = default_node
  }
  for &entry, idx in scene.nodes.entries do if entry.active {
    if idx >= len(matrices) do continue
    matrices[idx] = get_world_matrix(&entry.item)
    if idx >= len(node_datas) do continue
    mesh_attachment, has_mesh := entry.item.attachment.(MeshAttachment)
    if !has_mesh {
      continue
    }
    node_data := &node_datas[idx]
    node_data.material_id = mesh_attachment.material.index
    node_data.mesh_id = mesh_attachment.handle.index
    node_data.flags = {}
    if entry.item.visible && entry.item.parent_visible {
      node_data.flags |= {.VISIBLE}
    }
    if entry.item.culling_enabled {
      node_data.flags |= {.CULLING_ENABLED}
    }
    if mesh_attachment.cast_shadow {
      node_data.flags |= {.CASTS_SHADOW}
    }
    if material_entry, has_material := resource.get(
      warehouse.materials,
      mesh_attachment.material,
    ); has_material {
      switch material_entry.type {
      case .TRANSPARENT:
        node_data.flags |= {.MATERIAL_TRANSPARENT}
      case .WIREFRAME:
        node_data.flags |= {.MATERIAL_WIREFRAME}
      case .PBR, .UNLIT:
        // No additional flags needed
      }
    }
    if skinning, has_skinning := mesh_attachment.skinning.?; has_skinning {
      node_data.bone_matrix_offset = get_frame_bone_matrix_offset(
        warehouse,
        skinning.bone_matrix_offset,
        frame_index,
      )
    } else {
      node_data.bone_matrix_offset = 0xFFFFFFFF
    }
  }
}
