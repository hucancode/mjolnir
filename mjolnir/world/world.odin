package world

import animation "../animation"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import geometry "../geometry"
import gpu "../gpu"
import particles "../render/particles"
import resources "../resources"
import vk "vendor:vulkan"

Handle :: resources.Handle

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

TraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

FrameContext :: struct {
  frame_index: u32,
  delta_time:  f32,
  camera:      ^geometry.Camera,
}

DrawCommandRequest :: struct {
  camera_handle:  Handle,
  include_flags:  resources.NodeFlagSet,
  exclude_flags:  resources.NodeFlagSet,
  category:       VisibilityCategory,
}

DrawCommandList :: struct {
  draw_buffer:    vk.Buffer,
  count_buffer:   vk.Buffer,
  max_draws:      u32,
  command_stride: u32,
}

init_node :: proc(self: ^Node, name: string = "") {
  self.children = make([dynamic]Handle, 0)
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.culling_enabled = true
  self.visible = true
  self.parent_visible = true
}

deinit_node :: proc(self: ^Node, resources_manager: ^resources.Manager) {
  delete(self.children)
  if resources_manager == nil {
    return
  }
  if emitter_attachment, is_emitter := &self.attachment.(EmitterAttachment); is_emitter {
    if resources.destroy_emitter_handle(resources_manager, emitter_attachment.handle) {
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
  resources.slab_free(&resources_manager.bone_matrix_slab, skinning.bone_matrix_offset)
  skinning.bone_matrix_offset = 0xFFFFFFFF
}

detach :: proc(nodes: resources.Pool(Node), child_handle: Handle) {
  child_node := resources.get(nodes, child_handle)
  if child_node == nil {
    return
  }
  parent_handle := child_node.parent
  if parent_handle == child_handle {
    return
  }
  parent_node := resources.get(nodes, parent_handle)
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
  nodes: resources.Pool(Node),
  parent_handle, child_handle: Handle,
) {
  child_node := resources.get(nodes, child_handle)
  parent_node := resources.get(nodes, parent_handle)
  if child_node == nil || parent_node == nil {
    return
  }
  if old_parent_node, ok := resources.get(nodes, child_node.parent); ok {
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
  world: ^World,
  resources_manager: ^resources.Manager,
  node_handle: Handle,
  name: string,
  mode: animation.PlayMode = .LOOP,
) -> bool {
  if resources_manager == nil {
    return false
  }
  node := resources.get(world.nodes, node_handle)
  if node == nil {
    return false
  }
  data, ok := &node.attachment.(MeshAttachment)
  if !ok {
    return false
  }
  mesh := resources.get_mesh(resources_manager, data.handle)
  skinning, has_skin := &data.skinning.?
  if mesh == nil || !has_skin {
    return false
  }
  anim_inst, found := resources.make_animation_instance(resources_manager, name, mode)
  if !found {
    return false
  }
  skinning.animation = anim_inst
  return true
}

spawn_at :: proc(
  self: ^World,
  position: [3]f32,
  attachment: NodeAttachment = nil,
  resources_manager: ^resources.Manager = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resources.alloc(&self.nodes)
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(resources_manager, handle, node)
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
  attach(self.nodes, self.root, handle)
  return
}

spawn :: proc(
  self: ^World,
  attachment: NodeAttachment = nil,
  resources_manager: ^resources.Manager = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resources.alloc(&self.nodes)
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(resources_manager, handle, node)
  attach(self.nodes, self.root, handle)
  return
}

spawn_child :: proc(
  self: ^World,
  parent: Handle,
  attachment: NodeAttachment = nil,
  resources_manager: ^resources.Manager = nil,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = resources.alloc(&self.nodes)
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(resources_manager, handle, node)
  attach(self.nodes, parent, handle)
  return
}

TraverseEntry :: struct {
  handle:           Handle,
  parent_transform: matrix[4, 4]f32,
  parent_is_dirty:  bool,
  parent_is_visible: bool,
}

World :: struct {
  root:            Handle,
  nodes:           resources.Pool(Node),
  traversal_stack: [dynamic]TraverseEntry,
  visibility:      VisibilitySystem,
}

init :: proc(world: ^World) {
  resources.pool_init(&world.nodes)
  root: ^Node
  world.root, root = resources.alloc(&world.nodes)
  init_node(root, "root")
  root.parent = world.root
  world.traversal_stack = make([dynamic]TraverseEntry, 0)
}

deinit :: proc(world: ^World, resources_manager: ^resources.Manager) {
  for &entry in world.nodes.entries {
    if entry.active {
      deinit_node(&entry.item, resources_manager)
    }
  }
  resources.pool_deinit(world.nodes, proc(node: ^Node) {})
  delete(world.traversal_stack)
}

init_gpu :: proc(
  world: ^World,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  return visibility_system_init(&world.visibility, gpu_context, resources_manager)
}

deinit_gpu :: proc(
  world: ^World,
  gpu_context: ^gpu.GPUContext,
) {
  visibility_system_deinit(&world.visibility, gpu_context)
}

begin_frame :: proc(world: ^World, frame_ctx: ^FrameContext) {
  traverse(world)
  update_visibility_system(world)
}

// Main API for render subsystems to request draw commands
query_visibility :: proc(
  world: ^World,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  request: DrawCommandRequest,
) -> DrawCommandList {
  visibility_request := VisibilityRequest {
    camera_index  = request.camera_handle.index,
    include_flags = request.include_flags,
    exclude_flags = request.exclude_flags,
  }

  result := visibility_system_dispatch(
    &world.visibility,
    gpu_context,
    command_buffer,
    frame_index,
    request.category,
    visibility_request,
  )

  return DrawCommandList {
    draw_buffer    = result.draw_buffer,
    count_buffer   = result.count_buffer,
    max_draws      = result.max_draws,
    command_stride = result.command_stride,
  }
}

shutdown :: proc(world: ^World, gpu_context: ^gpu.GPUContext, resources_manager: ^resources.Manager) {
  deinit_gpu(world, gpu_context)
  deinit(world, resources_manager)
}

// Legacy compatibility functions for render subsystem
dispatch_visibility :: proc(
  world: ^World,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  category: VisibilityCategory,
  request: VisibilityRequest,
) -> VisibilityResult {
  return visibility_system_dispatch(
    &world.visibility,
    gpu_context,
    command_buffer,
    frame_index,
    category,
    request,
  )
}

visibility_command_stride :: proc() -> u32 {
  return visibility_system_command_stride()
}

// Node management API
spawn_node :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  attachment: NodeAttachment = nil,
  resources_manager: ^resources.Manager = nil,
) -> (handle: Handle, node: ^Node) {
  handle, node = resources.alloc(&world.nodes)
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(resources_manager, handle, node)
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
  attach(world.nodes, world.root, handle)
  return
}

spawn_child_node :: proc(
  world: ^World,
  parent: Handle,
  position: [3]f32 = {0, 0, 0},
  attachment: NodeAttachment = nil,
  resources_manager: ^resources.Manager = nil,
) -> (handle: Handle, node: ^Node) {
  handle, node = resources.alloc(&world.nodes)
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(resources_manager, handle, node)
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
  attach(world.nodes, parent, handle)
  return
}

destroy_node :: proc(world: ^World, handle: Handle) -> bool {
  node := resources.get(world.nodes, handle)
  if node == nil {
    return false
  }
  if !node.pending_deletion {
    node.pending_deletion = true
    detach(world.nodes, handle)
  }
  return true
}

get_node :: proc(world: ^World, handle: Handle) -> ^Node {
  return resources.get(world.nodes, handle)
}

// Emitter synchronization for particle system
sync_emitters :: proc(
  world: ^World,
  resources_manager: ^resources.Manager,
  emitters: []resources.EmitterData,
  params: ^particles.ParticleSystemParams,
) {
  if resources_manager == nil {
    params.emitter_count = 0
    return
  }

  emitter_capacity := len(emitters)
  max_slots := emitter_capacity
  if max_slots > particles.MAX_EMITTERS {
    max_slots = particles.MAX_EMITTERS
  }
  params.emitter_count = u32(max_slots)

  // Reset visibility each frame; preserve accumulator
  for i in 0 ..< emitter_capacity {
    emitters[i].visible = cast(b32)false
  }

  for &entry, index in resources_manager.emitters.entries {
    if index >= emitter_capacity {
      log.warnf("Emitter index %d exceeds GPU buffer capacity %d", index, emitter_capacity)
      continue
    }
    gpu_emitter := &emitters[index]
    if !entry.active {
      preserved_time := gpu_emitter.time_accumulator
      entry.item.node_handle = {}
      entry.item.is_dirty = true
      gpu_emitter^ = resources.EmitterData{
        time_accumulator = preserved_time,
        visible = cast(b32)false,
      }
      continue
    }

    emitter := &entry.item
    node_handle := emitter.node_handle
    node := resources.get(world.nodes, node_handle)

    if node == nil || node.pending_deletion {
      emitter.is_dirty = true
      preserved_time := gpu_emitter.time_accumulator
      gpu_emitter^ = resources.EmitterData{
        time_accumulator = preserved_time,
        visible = cast(b32)false,
      }
      continue
    }

    visible := node.parent_visible && node.visible && emitter.enabled != b32(false)
    if emitter.is_dirty {
      preserved_time := gpu_emitter.time_accumulator
      gpu_emitter^ = resources.EmitterData {
        initial_velocity  = emitter.initial_velocity,
        color_start       = emitter.color_start,
        color_end         = emitter.color_end,
        emission_rate     = emitter.emission_rate,
        particle_lifetime = emitter.particle_lifetime,
        position_spread   = emitter.position_spread,
        velocity_spread   = emitter.velocity_spread,
        time_accumulator  = preserved_time,
        size_start        = emitter.size_start,
        size_end          = emitter.size_end,
        weight            = emitter.weight,
        weight_spread     = emitter.weight_spread,
        texture_index     = emitter.texture_handle.index,
        node_index        = node_handle.index,
        visible           = cast(b32)visible,
        aabb_min          = {
          emitter.bounding_box.min.x,
          emitter.bounding_box.min.y,
          emitter.bounding_box.min.z,
          0.0,
        },
        aabb_max          = {
          emitter.bounding_box.max.x,
          emitter.bounding_box.max.y,
          emitter.bounding_box.max.z,
          0.0,
        },
      }
      emitter.is_dirty = false
    } else {
      gpu_emitter.visible = cast(b32)visible
      gpu_emitter.node_index = node_handle.index
    }
    emitter.node_handle = node_handle
  }
}

// Matrix upload for rendering
upload_world_matrices :: proc(
  world: ^World,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  if frame_index >= resources.MAX_FRAMES_IN_FLIGHT {
    return
  }
  matrices := gpu.data_buffer_get_all(&resources_manager.world_matrix_buffers[frame_index])
  node_datas := gpu.data_buffer_get_all(&resources_manager.node_data_buffer)
  if len(matrices) == 0 {
    return
  }
  identity := linalg.MATRIX4F32_IDENTITY
  for i in 0 ..< len(matrices) {
    matrices[i] = identity
  }
  default_node := resources.NodeData {
    material_id        = 0xFFFFFFFF,
    mesh_id            = 0xFFFFFFFF,
    bone_matrix_offset = 0xFFFFFFFF,
    flags              = {},
  }
  for i in 0 ..< len(node_datas) {
    node_datas[i] = default_node
  }
  for &entry, idx in world.nodes.entries do if entry.active {
    if idx >= len(matrices) do continue
    matrices[idx] = node_get_world_matrix(&entry.item)
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
    if material_entry, has_material := resources.get(
      resources_manager.materials,
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
      node_data.bone_matrix_offset = skinning.bone_matrix_offset
    } else {
      node_data.bone_matrix_offset = 0xFFFFFFFF
    }
  }
}

// Internal helper procedures
@(private)
update_visibility_system :: proc(world: ^World) {
  count: u32 = 0
  for entry in world.nodes.entries do if entry.active {
    count += 1
  }
  visibility_system_set_node_count(&world.visibility, count)
}

traverse :: proc(world: ^World, cb_context: rawptr = nil, callback: TraversalCallback = nil) -> bool {
  using geometry
  append(
    &world.traversal_stack,
    TraverseEntry{world.root, linalg.MATRIX4F32_IDENTITY, false, true},
  )
  for len(world.traversal_stack) > 0 {
    entry := pop(&world.traversal_stack)
    current_node, found := resources.get(world.nodes, entry.handle)
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
        &world.traversal_stack,
        TraverseEntry {
          child_handle,
          node_get_world_matrix(current_node),
          is_dirty || entry.parent_is_dirty,
          current_node.parent_visible && current_node.visible, // Pass combined visibility to children
        },
      )
    }
  }
  return true
}

@(private)
assign_emitter_to_node :: proc(
  resources_manager: ^resources.Manager,
  node_handle: Handle,
  node: ^Node,
) {
  if resources_manager == nil {
    return
  }
  attachment, is_emitter := &node.attachment.(EmitterAttachment)
  if !is_emitter {
    return
  }
  emitter, ok := resources.get(resources_manager.emitters, attachment.handle)
  if ok {
    emitter.node_handle = node_handle
    emitter.is_dirty = true
  }
}

node_get_world_matrix :: proc(node: ^Node) -> matrix[4,4]f32 {
  return geometry.transform_get_world_matrix(&node.transform)
}

// Legacy compatibility functions - these maintain the existing API
// for transition period but delegate to the new structured API

mark_for_despawn :: proc(world: ^World, handle: Handle) -> bool {
  return destroy_node(world, handle)
}

mark_emitter_dirty :: proc(
  world: ^World,
  resources_manager: ^resources.Manager,
  handle: Handle,
) {
  node := resources.get(world.nodes, handle)
  if node == nil {
    return
  }
  attachment, is_emitter := &node.attachment.(EmitterAttachment)
  if !is_emitter {
    return
  }
  emitter, ok := resources.get(resources_manager.emitters, attachment.handle)
  if ok {
    emitter.is_dirty = true
  }
}

// Transform manipulation convenience functions (legacy API)
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
node_handle_translate_by :: proc(world: ^World, handle: Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_translate_by(&node.transform, x, y, z)
  }
}

node_handle_translate :: proc(world: ^World, handle: Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_translate(&node.transform, x, y, z)
  }
}

node_handle_rotate_by :: proc {
  node_handle_rotate_by_quaternion,
  node_handle_rotate_by_angle,
}

node_handle_rotate_by_quaternion :: proc(world: ^World, handle: Handle, q: quaternion128) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_rotate_by_quaternion(&node.transform, q)
  }
}

node_handle_rotate_by_angle :: proc(
  world: ^World,
  handle: Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_rotate_by_angle(&node.transform, angle, axis)
  }
}

node_handle_rotate :: proc {
  node_handle_rotate_quaternion,
  node_handle_rotate_angle,
}

node_handle_rotate_quaternion :: proc(world: ^World, handle: Handle, q: quaternion128) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_rotate_quaternion(&node.transform, q)
  }
}

node_handle_rotate_angle :: proc(
  world: ^World,
  handle: Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_rotate_angle(&node.transform, angle, axis)
  }
}

node_handle_scale_xyz_by :: proc(world: ^World, handle: Handle, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_scale_xyz_by(&node.transform, x, y, z)
  }
}

node_handle_scale_by :: proc(world: ^World, handle: Handle, s: f32) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_scale_by(&node.transform, s)
  }
}

node_handle_scale_xyz :: proc(world: ^World, handle: Handle, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_scale_xyz(&node.transform, x, y, z)
  }
}

node_handle_scale :: proc(world: ^World, handle: Handle, s: f32) {
  if node := resources.get(world.nodes, handle); node != nil {
    geometry.transform_scale(&node.transform, s)
  }
}
