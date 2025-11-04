package world

import cont "../containers"
import anim "../animation"
import "../geometry"
import "../gpu"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

LightAttachment :: struct {
  handle: resources.Handle,
}

NodeSkinning :: struct {
  layers:                    [dynamic]anim.Layer, // Animation layers (FK + IK)
  bone_matrix_buffer_offset: u32,                 // offset into bone matrix buffer for skinned mesh
}

// Configuration for an N-bone IK chain (minimum 2 bones)
// Stores bone names (resolved to indices at runtime) and world-space target positions
IKConfig :: struct {
  bone_names:       []string, // all bones in chain from root to end (min 2)
  target_position:  [3]f32,   // world-space position for end effector
  pole_position:    [3]f32,   // world-space pole hint (bending direction)
  max_iterations:   int,      // FABRIK iterations (default: 10)
  tolerance:        f32,      // convergence threshold (default: 0.001)
  weight:           f32,      // blend weight (0-1), 1 = full IK
  enabled:          bool,
}

MeshAttachment :: struct {
  handle:              resources.Handle,
  material:            resources.Handle,
  skinning:            Maybe(NodeSkinning),
  ik_configs:          [dynamic]IKConfig, // IK constraints for this mesh
  cast_shadow:         bool,
  navigation_obstacle: bool,
}

EmitterAttachment :: struct {
  handle: resources.Handle,
}

ForceFieldAttachment :: struct {
  handle: resources.Handle,
}

SpriteAttachment :: struct {
  sprite_handle: resources.Handle,
  mesh_handle:   resources.Handle,
  material:      resources.Handle,
}

NodeAttachment :: union {
  LightAttachment,
  MeshAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
  NavMeshAgentAttachment,
  NavMeshObstacleAttachment,
  SpriteAttachment,
}

NodeTag :: enum u32 {
  PAWN, // generic game entities (players, AI, etc.)
  ACTOR, // generic game actor
  MESH, // has mesh attachment
  SPRITE, // has sprite attachment
  LIGHT, // has light attachment
  EMITTER, // has particle emitter
  FORCEFIELD, // has force field
  VISIBLE, // currently visible (own + parent visibility)
  NAVMESH_AGENT, // has navigation agent
  NAVMESH_OBSTACLE, // is navigation obstacle
  INTERACTIVE, // can be interacted with
  ENEMY, // enemy entity
  FRIENDLY, // friendly entity
  PROJECTILE, // projectile entity
  STATIC, // static, non-moving entity
  DYNAMIC, // dynamic, moving entity
}

NodeTagSet :: bit_set[NodeTag;u32]

// AnimationInstance represents a playing animation clip on a node
// Uses handle-based lookup to avoid pointer invalidation when pools resize
AnimationInstance :: struct {
  clip_handle: resources.Handle, // handle to animation clip (resolved at runtime)
  mode:        anim.PlayMode,
  status:      anim.Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

Node :: struct {
  parent:           resources.Handle,
  children:         [dynamic]resources.Handle,
  transform:        geometry.Transform,
  name:             string,
  bone_socket:      string, // if not empty, attach to this bone on parent skinned mesh
  attachment:       NodeAttachment,
  animation:        Maybe(AnimationInstance),
  culling_enabled:  bool,
  visible:          bool, // node's own visibility state
  parent_visible:   bool, // visibility inherited from parent chain
  pending_deletion: bool, // atomic flag for safe deletion
  tags:             NodeTagSet, // tags for queries and filtering
}

TraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

FrameContext :: struct {
  frame_index: u32,
  delta_time:  f32,
  camera:      ^resources.Camera,
}

init_node :: proc(self: ^Node, name: string = "") {
  self.children = make([dynamic]resources.Handle, 0)
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.bone_socket = ""
  self.culling_enabled = true
  self.visible = true
  self.parent_visible = true
  self.pending_deletion = false
  self.tags = {}
}

update_node_tags :: proc(node: ^Node) {
  #partial switch _ in node.attachment {
  case MeshAttachment:
    node.tags |= {.MESH}
  case SpriteAttachment:
    node.tags |= {.SPRITE}
  case LightAttachment:
    node.tags |= {.LIGHT}
  case EmitterAttachment:
    node.tags |= {.EMITTER}
  case ForceFieldAttachment:
    node.tags |= {.FORCEFIELD}
  case NavMeshAgentAttachment:
    node.tags |= {.NAVMESH_AGENT}
  case NavMeshObstacleAttachment:
    node.tags |= {.NAVMESH_OBSTACLE}
  }
  if node.visible && node.parent_visible {
    node.tags |= {.VISIBLE}
  } else {
    node.tags -= {.VISIBLE}
  }
}

destroy_node :: proc(
  self: ^Node,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
) {
  delete(self.children)
  if rm == nil {
    return
  }
  #partial switch &attachment in &self.attachment {
  case LightAttachment:
    resources.destroy_light(rm, gctx, attachment.handle)
    attachment.handle = {}
  case EmitterAttachment:
    resources.destroy_emitter_handle(rm, attachment.handle)
    attachment.handle = {}
  case ForceFieldAttachment:
    resources.destroy_forcefield_handle(rm, attachment.handle)
    attachment.handle = {}
  case SpriteAttachment:
    resources.destroy_sprite_handle(rm, attachment.sprite_handle)
    attachment.sprite_handle = {}
  case MeshAttachment:
    resources.mesh_unref(rm, attachment.handle)
    resources.material_unref(rm, attachment.material)
    skinning, has_skin := &attachment.skinning.?
    if has_skin {
      if skinning.bone_matrix_buffer_offset != 0xFFFFFFFF {
        cont.slab_free(
          &rm.bone_matrix_slab,
          skinning.bone_matrix_buffer_offset,
        )
        skinning.bone_matrix_buffer_offset = 0xFFFFFFFF
      }
      delete(skinning.layers)
    }
    for &config in attachment.ik_configs {
      for name in config.bone_names {
        delete(name)
      }
      delete(config.bone_names)
    }
    delete(attachment.ik_configs)
  }
}

// add an N-bone IK constraint (minimum 2 bones)
// update target/pole positions every frame using set_ik_target()
add_ik :: proc(
  node: ^Node,
  bone_names: []string,
  target_pos: [3]f32,
  pole_pos: [3]f32,
  weight: f32 = 1.0,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
) {
  mesh_attachment, is_mesh := &node.attachment.(MeshAttachment)
  if !is_mesh do return
  if len(bone_names) < 2 do return
  cloned_names := make([]string, len(bone_names))
  for name, i in bone_names {
    cloned_names[i] = strings.clone(name)
  }
  config := IKConfig {
    bone_names      = cloned_names,
    target_position = target_pos,
    pole_position   = pole_pos,
    max_iterations  = max_iterations,
    tolerance       = tolerance,
    weight          = clamp(weight, 0.0, 1.0),
    enabled         = true,
  }
  append(&mesh_attachment.ik_configs, config)
}

set_ik_enabled :: proc(node: ^Node, index: int, enabled: bool) {
  mesh_attachment, is_mesh := &node.attachment.(MeshAttachment)
  if !is_mesh do return
  if index < 0 || index >= len(mesh_attachment.ik_configs) do return
  mesh_attachment.ik_configs[index].enabled = enabled
}

set_ik_target :: proc(node: ^Node, index: int, target_pos, pole_pos: [3]f32) {
  mesh_attachment, is_mesh := &node.attachment.(MeshAttachment)
  if !is_mesh do return
  if index < 0 || index >= len(mesh_attachment.ik_configs) do return
  mesh_attachment.ik_configs[index].target_position = target_pos
  mesh_attachment.ik_configs[index].pole_position = pole_pos
}

clear_ik :: proc(node: ^Node) {
  mesh_attachment, is_mesh := &node.attachment.(MeshAttachment)
  if !is_mesh do return
  for &config in mesh_attachment.ik_configs {
    for name in config.bone_names {
      delete(name)
    }
    delete(config.bone_names)
  }
  clear(&mesh_attachment.ik_configs)
}

detach :: proc(nodes: resources.Pool(Node), child_handle: resources.Handle) {
  child_node := cont.get(nodes, child_handle)
  if child_node == nil {
    return
  }
  parent_handle := child_node.parent
  if parent_handle == child_handle {
    return
  }
  parent_node := cont.get(nodes, parent_handle)
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
  parent_handle, child_handle: resources.Handle,
) {
  child_node := cont.get(nodes, child_handle)
  parent_node := cont.get(nodes, parent_handle)
  if child_node == nil || parent_node == nil {
    return
  }
  if old_parent_node, ok := cont.get(nodes, child_node.parent); ok {
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

// Play animation on layer 0 (for backward compatibility)
play_animation :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.Handle,
  name: string,
  mode: anim.PlayMode = .LOOP,
  speed: f32 = 1.0,
) -> bool {
  return add_animation_layer(world, rm, node_handle, name, 1.0, mode, speed, 0)
}

// Add or replace an animation layer at specified index
add_animation_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.Handle,
  animation_name: string,
  weight: f32 = 1.0,
  mode: anim.PlayMode = .LOOP,
  speed: f32 = 1.0,
  layer_index: int = -1, // -1 means append new layer
) -> bool {
  if rm == nil do return false
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  mesh := cont.get(rm.meshes, mesh_attachment.handle) or_return

  // Get or initialize skinning
  if skinning_ptr, has_skin := &mesh_attachment.skinning.?; has_skin {
    // Skinning already exists, use it
  } else {
    // Initialize skinning with empty layers
    mesh_attachment.skinning = NodeSkinning {
      layers = make([dynamic]anim.Layer, 0),
      bone_matrix_buffer_offset = 0xFFFFFFFF,
    }
  }

  skinning := &mesh_attachment.skinning.?

  // Find animation clip handle and duration
  clip_handle: resources.Handle
  clip_duration: f32
  found := false
  for &entry, idx in rm.animation_clips.entries do if entry.active {
    if entry.item.name == animation_name {
      clip_handle = resources.Handle{index = u32(idx), generation = entry.generation}
      clip_duration = entry.item.duration
      found = true
      break
    }
  }
  if !found do return false

  // Create new layer with handle
  layer := anim.Layer{}
  clip_handle_u64 := transmute(u64)clip_handle
  anim.layer_init_fk(&layer, clip_handle_u64, clip_duration, weight, mode, speed)

  // Add or replace layer
  if layer_index >= 0 && layer_index < len(skinning.layers) {
    skinning.layers[layer_index] = layer
  } else {
    append(&skinning.layers, layer)
  }

  return true
}

// Remove animation layer at specified index
remove_animation_layer :: proc(
  world: ^World,
  node_handle: resources.Handle,
  layer_index: int,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  unordered_remove(&skinning.layers, layer_index)
  return true
}

// Set weight for an animation layer
set_animation_layer_weight :: proc(
  world: ^World,
  node_handle: resources.Handle,
  layer_index: int,
  weight: f32,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  skinning.layers[layer_index].weight = clamp(weight, 0.0, 1.0)
  return true
}

// Clear all animation layers
clear_animation_layers :: proc(
  world: ^World,
  node_handle: resources.Handle,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false

  clear(&skinning.layers)
  return true
}

// Add an IK layer at specified index
// IK targets are in world space and will be converted to skeleton-local space internally
add_ik_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.Handle,
  bone_names: []string,
  target_world_pos: [3]f32,
  pole_world_pos: [3]f32,
  weight: f32 = 1.0,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  layer_index: int = -1, // -1 to append, >= 0 to replace existing layer
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  mesh := cont.get(rm.meshes, mesh_attachment.handle) or_return

  // Get or initialize skinning
  if skinning_ptr, has_skin := &mesh_attachment.skinning.?; has_skin {
    // Skinning already exists
  } else {
    // Initialize skinning with empty layers
    mesh_attachment.skinning = NodeSkinning {
      layers = make([dynamic]anim.Layer, 0),
      bone_matrix_buffer_offset = 0xFFFFFFFF,
    }
  }

  skinning := &mesh_attachment.skinning.?

  // Resolve bone names to indices
  if len(bone_names) < 2 do return false
  bone_indices := make([]u32, len(bone_names))
  for name, i in bone_names {
    idx, ok := resources.find_bone_by_name(mesh, name)
    if !ok {
      delete(bone_indices)
      return false
    }
    bone_indices[i] = idx
  }

  // Transform IK target from world space to skeleton-local space
  node_world_inv := linalg.matrix4_inverse(node.transform.world_matrix)
  target_world_h := linalg.Vector4f32{target_world_pos.x, target_world_pos.y, target_world_pos.z, 1.0}
  pole_world_h := linalg.Vector4f32{pole_world_pos.x, pole_world_pos.y, pole_world_pos.z, 1.0}
  target_local_h := node_world_inv * target_world_h
  pole_local_h := node_world_inv * pole_world_h
  target_local := target_local_h.xyz
  pole_local := pole_local_h.xyz

  // Create IK target (in skeleton-local space)
  ik_target := anim.IKTarget {
    bone_indices    = bone_indices,
    target_position = target_local,
    pole_vector     = pole_local,
    max_iterations  = max_iterations,
    tolerance       = tolerance,
    weight          = clamp(weight, 0.0, 1.0),
    enabled         = true,
  }

  // Create IK layer
  layer := anim.Layer{}
  anim.layer_init_ik(&layer, ik_target, weight)

  // Add or replace layer
  if layer_index >= 0 && layer_index < len(skinning.layers) {
    skinning.layers[layer_index] = layer
  } else {
    append(&skinning.layers, layer)
  }

  return true
}

// Update IK target position and pole vector for an existing IK layer
// Targets are in world space and will be converted to skeleton-local space internally
set_ik_layer_target :: proc(
  world: ^World,
  node_handle: resources.Handle,
  layer_index: int,
  target_world_pos: [3]f32,
  pole_world_pos: [3]f32,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  // Transform from world space to skeleton-local space
  node_world_inv := linalg.matrix4_inverse(node.transform.world_matrix)
  target_world_h := linalg.Vector4f32{target_world_pos.x, target_world_pos.y, target_world_pos.z, 1.0}
  pole_world_h := linalg.Vector4f32{pole_world_pos.x, pole_world_pos.y, pole_world_pos.z, 1.0}
  target_local_h := node_world_inv * target_world_h
  pole_local_h := node_world_inv * pole_world_h
  target_local := target_local_h.xyz
  pole_local := pole_local_h.xyz

  // Check if this is an IK layer
  switch &layer_data in skinning.layers[layer_index].data {
  case anim.IKLayer:
    layer_data.target.target_position = target_local
    layer_data.target.pole_vector = pole_local
    return true
  case anim.FKLayer:
    return false
  }

  return false
}

// Enable or disable an IK layer
set_ik_layer_enabled :: proc(
  world: ^World,
  node_handle: resources.Handle,
  layer_index: int,
  enabled: bool,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  // Check if this is an IK layer
  switch &layer_data in skinning.layers[layer_index].data {
  case anim.IKLayer:
    layer_data.target.enabled = enabled
    return true
  case anim.FKLayer:
    return false
  }

  return false
}

@(private = "file")
_spawn_internal :: proc(
  world: ^World,
  parent: resources.Handle,
  position: [3]f32,
  attachment: NodeAttachment,
  rm: ^resources.Manager,
) -> (
  handle: resources.Handle,
  node: ^Node,
  ok: bool,
) {
  handle, node = cont.alloc(&world.nodes) or_return
  _init_node_with_attachment(node, attachment, handle, rm)
  geometry.transform_translate(
    &node.transform,
    position.x,
    position.y,
    position.z,
  )
  attach(world.nodes, parent, handle)
  if rm != nil {
    _upload_node_to_gpu(handle, node, rm)
  }
  world.octree_dirty_set[handle] = true
  return handle, node, true
}

@(private = "file")
_init_node_with_attachment :: proc(
  node: ^Node,
  attachment: NodeAttachment,
  handle: resources.Handle,
  rm: ^resources.Manager,
) {
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(rm, handle, node)
  assign_forcefield_to_node(rm, handle, node)
  assign_light_to_node(rm, handle, node)
  update_node_tags(node)
}

@(private = "file")
_upload_node_to_gpu :: proc(
  handle: resources.Handle,
  node: ^Node,
  rm: ^resources.Manager,
) {
  resources.node_upload_transform(rm, handle, &node.transform.world_matrix)
  data := _build_node_data(node, rm)
  resources.node_upload_data(rm, handle, &data)
}

@(private = "file")
_apply_sprite_to_node_data :: proc(
  data: ^resources.NodeData,
  sprite_attachment: SpriteAttachment,
  node: ^Node,
  rm: ^resources.Manager,
) {
  data.material_id = sprite_attachment.material.index
  data.mesh_id = sprite_attachment.mesh_handle.index
  data.attachment_data_index = sprite_attachment.sprite_handle.index
  if node.visible && node.parent_visible do data.flags |= {.VISIBLE}
  if node.culling_enabled do data.flags |= {.CULLING_ENABLED}
  // Mark as sprite
  data.flags |= {.MATERIAL_SPRITE}
  if material, has_mat := cont.get(
    rm.materials,
    sprite_attachment.material,
  ); has_mat {
    switch material.type {
    case .TRANSPARENT:
      data.flags |= {.MATERIAL_TRANSPARENT}
    case .WIREFRAME:
      data.flags |= {.MATERIAL_WIREFRAME}
    case .PBR, .UNLIT: // No flags
    }
  }
}

@(private = "file")
_build_node_data :: proc(
  node: ^Node,
  rm: ^resources.Manager,
) -> resources.NodeData {
  data := resources.NodeData {
    material_id           = 0xFFFFFFFF,
    mesh_id               = 0xFFFFFFFF,
    attachment_data_index = 0xFFFFFFFF,
    flags                 = {},
  }
  if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
    data.material_id = mesh_attachment.material.index
    data.mesh_id = mesh_attachment.handle.index
    // FIX: Must check both node.visible AND node.parent_visible (same as traverse logic)
    if node.visible && node.parent_visible do data.flags |= {.VISIBLE}
    if node.culling_enabled do data.flags |= {.CULLING_ENABLED}
    if mesh_attachment.cast_shadow do data.flags |= {.CASTS_SHADOW}
    if mesh_attachment.navigation_obstacle do data.flags |= {.NAVIGATION_OBSTACLE}
    if material, has_mat := cont.get(
      rm.materials,
      mesh_attachment.material,
    ); has_mat {
      switch material.type {
      case .TRANSPARENT:
        data.flags |= {.MATERIAL_TRANSPARENT}
      case .WIREFRAME:
        data.flags |= {.MATERIAL_WIREFRAME}
      case .PBR, .UNLIT: // No flags
      }
    }
    if skinning, has_skin := mesh_attachment.skinning.?; has_skin {
      data.attachment_data_index = skinning.bone_matrix_buffer_offset
    }
  }
  if sprite_attachment, has_sprite := node.attachment.(SpriteAttachment);
     has_sprite {
    _apply_sprite_to_node_data(&data, sprite_attachment, node, rm)
  }
  if _, is_obstacle := node.attachment.(NavMeshObstacleAttachment);
     is_obstacle {
    data.flags |= {.NAVIGATION_OBSTACLE}
  }
  return data
}

spawn_at :: proc(
  self: ^World,
  position: [3]f32,
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  handle: resources.Handle,
  node: ^Node,
  ok: bool,
) {
  return _spawn_internal(self, self.root, position, attachment, rm)
}

spawn :: proc(
  self: ^World,
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  handle: resources.Handle,
  node: ^Node,
  ok: bool,
) {
  return _spawn_internal(self, self.root, {0, 0, 0}, attachment, rm)
}

spawn_child :: proc(
  self: ^World,
  parent: resources.Handle,
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  handle: resources.Handle,
  node: ^Node,
  ok: bool,
) {
  return _spawn_internal(self, parent, {0, 0, 0}, attachment, rm)
}

TraverseEntry :: struct {
  handle:            resources.Handle,
  parent_transform:  matrix[4, 4]f32,
  parent_is_dirty:   bool,
  parent_is_visible: bool,
}

World :: struct {
  root:                   resources.Handle,
  nodes:                  resources.Pool(Node),
  traversal_stack:        [dynamic]TraverseEntry,
  visibility:             VisibilitySystem,
  node_octree:            geometry.Octree(NodeEntry),
  octree_entry_map:       map[resources.Handle]NodeEntry,
  octree_dirty_set:       map[resources.Handle]bool, // nodes needing octree update
  octree_updates_enabled: bool,
  actor_pools:            map[typeid]ActorPoolEntry,
}

init :: proc(world: ^World) {
  cont.init(&world.nodes, resources.MAX_NODES_IN_SCENE)
  root: ^Node
  world.root, root, _ = cont.alloc(&world.nodes)
  init_node(root, "root")
  root.parent = world.root
  world.traversal_stack = make([dynamic]TraverseEntry, 0)
  world.actor_pools = make(map[typeid]ActorPoolEntry)
  max_depth, max_items := compute_octree_params(resources.MAX_NODES_IN_SCENE)
  geometry.octree_init(
    &world.node_octree,
    geometry.Aabb{min = {-1000, -1000, -1000}, max = {1000, 1000, 1000}},
    max_depth = max_depth,
    max_items = max_items,
  )
  world.node_octree.bounds_func = node_entry_to_aabb
  world.node_octree.point_func = node_entry_to_point
  world.octree_entry_map = make(map[resources.Handle]NodeEntry)
  world.octree_dirty_set = make(map[resources.Handle]bool)
  world.octree_updates_enabled = true
}

compute_octree_params :: proc(expected_object_count: int) -> (max_depth: i32, max_items: i32) {
  max_depth = 8
  max_items = 32
  if expected_object_count > 100000 {
    max_depth = 10
    max_items = 128
  } else if expected_object_count > 10000 {
    max_depth = 9
    max_items = 64
  } else if expected_object_count > 1000 {
    max_depth = 8
    max_items = 32
  }
  return max_depth, max_items
}

set_octree_bounds :: proc(world: ^World, bounds: geometry.Aabb) {
  if world.node_octree.root != nil {
    geometry.octree_destroy(&world.node_octree)
  }
  max_depth, max_items := compute_octree_params(resources.MAX_NODES_IN_SCENE)
  geometry.octree_init(&world.node_octree, bounds, max_depth, max_items)
  world.node_octree.bounds_func = node_entry_to_aabb
  world.node_octree.point_func = node_entry_to_point
  clear(&world.octree_entry_map)
  clear(&world.octree_dirty_set)
}

set_octree_updates_enabled :: proc(world: ^World, enabled: bool) {
  world.octree_updates_enabled = enabled
}

force_octree_rebuild :: proc(world: ^World, rm: ^resources.Manager) {
  clear(&world.octree_entry_map)
  geometry.octree_destroy(&world.node_octree)
  max_depth, max_items := compute_octree_params(resources.MAX_NODES_IN_SCENE)
  geometry.octree_init(
    &world.node_octree,
    geometry.Aabb{min = {-1000, -1000, -1000}, max = {1000, 1000, 1000}},
    max_depth,
    max_items,
  )
  world.node_octree.bounds_func = node_entry_to_aabb
  world.node_octree.point_func = node_entry_to_point
  for &entry, i in world.nodes.entries {
    if !entry.active || entry.item.pending_deletion do continue
    handle := resources.Handle{index = u32(i), generation = entry.generation}
    world.octree_dirty_set[handle] = true
  }
}

destroy :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
) {
  for &entry in world.nodes.entries {
    if entry.active {
      destroy_node(&entry.item, rm, gctx)
    }
  }
  cont.destroy(world.nodes, proc(node: ^Node) {})
  delete(world.traversal_stack)
  for _, entry in world.actor_pools {
    entry.destroy_fn(entry.pool_ptr)
  }
  delete(world.actor_pools)
  geometry.octree_destroy(&world.node_octree)
  delete(world.octree_entry_map)
  delete(world.octree_dirty_set)
}

init_gpu :: proc(
  world: ^World,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  depth_width: u32,
  depth_height: u32,
) -> vk.Result {
  visibility_system_init(
    &world.visibility,
    gctx,
    rm,
    depth_width,
    depth_height,
  ) or_return
  return .SUCCESS
}

begin_frame :: proc(
  world: ^World,
  rm: ^resources.Manager,
  delta_time: f32 = 0.016,
  game_state: rawptr = nil,
) {
  traverse(world, rm)
  process_octree_updates(world, rm)
  update_visibility_system(world)
  world_tick_actors(world, rm, delta_time, game_state)
}

shutdown :: proc(
  world: ^World,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) {
  visibility_system_shutdown(&world.visibility, gctx, rm)
  destroy(world, rm, gctx)
}

despawn :: proc(world: ^World, handle: resources.Handle) -> bool {
  node := cont.get(world.nodes, handle)
  if node == nil {
    log.warnf("despawn: node %v not found (already freed or invalid)", handle)
    return false
  }
  if !node.pending_deletion {
    log.infof("despawn: marking node %v '%s' for deletion", handle, node.name)
    node.pending_deletion = true
    detach(world.nodes, handle)
  } else {
    log.warnf("despawn: node %v '%s' already marked for deletion", handle, node.name)
  }
  return true
}

cleanup_pending_deletions :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
) {
  to_destroy := make([dynamic]resources.Handle, 0)
  defer delete(to_destroy)

  // Count pending deletions for debugging
  pending_count := 0
  for i in 0 ..< len(world.nodes.entries) {
    entry := &world.nodes.entries[i]
    if entry.active && entry.item.pending_deletion {
      pending_count += 1
      append(
        &to_destroy,
        resources.Handle{index = u32(i), generation = entry.generation},
      )
    }
  }

  if pending_count > 0 {
    log.infof("Cleanup: found %d nodes marked for deletion", pending_count)
  }

  if len(to_destroy) > 0 {
    log.infof("Cleanup: destroying %d nodes", len(to_destroy))
  }

  for handle in to_destroy {
    node := cont.get(world.nodes, handle)
    if node != nil {
      log.infof("  Destroying node handle: %v name='%s'", handle, node.name)
    } else {
      log.warnf("  Node handle %v already gone!", handle)
    }

    // Clear GPU buffers BEFORE freeing the node
    if rm != nil {
      zero_matrix: matrix[4, 4]f32
      resources.node_upload_transform(rm, handle, &zero_matrix)
      zero_data: resources.NodeData
      zero_data.flags = {}  // Empty flags means not renderable
      resources.node_upload_data(rm, handle, &zero_data)
    }

    world.octree_dirty_set[handle] = true
    if node, ok := cont.free(&world.nodes, handle); ok {
      destroy_node(node, rm, gctx)
    }
  }
}

get_node :: proc(world: ^World, handle: resources.Handle) -> ^Node {
  return cont.get(world.nodes, handle)
}

@(private)
update_visibility_system :: proc(world: ^World) {
  // Find the highest active node index
  max_index: int = 0
  for i in 0..<len(world.nodes.entries) {
    if world.nodes.entries[i].active {
      max_index = i
    }
  }
  // node_count must be max_index + 1 so GPU processes all indices up to max
  node_count := u32(max_index + 1)
  visibility_system_set_node_count(&world.visibility, node_count)
}

traverse :: proc(
  world: ^World,
  rm: ^resources.Manager = nil,
  cb_context: rawptr = nil,
  callback: TraversalCallback = nil,
) -> bool {
  using geometry
  append(
    &world.traversal_stack,
    TraverseEntry{world.root, linalg.MATRIX4F32_IDENTITY, false, true},
  )
  for len(world.traversal_stack) > 0 {
    entry := pop(&world.traversal_stack)
    current_node := cont.get(world.nodes, entry.handle) or_continue
    if current_node.pending_deletion do continue
    visibility_changed :=
      current_node.parent_visible != entry.parent_is_visible
    current_node.parent_visible = entry.parent_is_visible
    is_dirty := transform_update_local(&current_node.transform)
    if visibility_changed {
      update_node_tags(current_node)
    }
    bone_socket_transform := linalg.MATRIX4F32_IDENTITY
    has_bone_socket := false
    apply_bone_socket: {
      if current_node.bone_socket == "" || rm == nil do break apply_bone_socket
      parent_node := cont.get(world.nodes, current_node.parent) or_break
      parent_mesh_attachment := parent_node.attachment.(MeshAttachment) or_break
      parent_mesh := cont.get(
        rm.meshes,
        parent_mesh_attachment.handle,
      ) or_break
      bone_index := resources.find_bone_by_name(
        parent_mesh,
        current_node.bone_socket,
      ) or_break
      parent_skinning := parent_mesh_attachment.skinning.? or_break
      if parent_skinning.bone_matrix_buffer_offset == 0xFFFFFFFF do break apply_bone_socket
      parent_mesh_skinning := parent_mesh.skinning.? or_break
      if bone_index >= u32(len(parent_mesh_skinning.bones)) do break apply_bone_socket
      bone_buffer := &rm.bone_buffer
      if bone_buffer.mapped == nil do break apply_bone_socket
      bone_matrices_ptr := gpu.mutable_buffer_get(
        bone_buffer,
        parent_skinning.bone_matrix_buffer_offset,
      )
      bone_matrices := slice.from_ptr(
        bone_matrices_ptr,
        len(parent_mesh_skinning.bones),
      )
      // bone_matrices contains skinning matrices (world_transform * inverse_bind)
      // to get the bone's world transform, multiply by the bind matrix
      skinning_matrix := bone_matrices[bone_index]
      bone := parent_mesh_skinning.bones[bone_index]
      bind_matrix := linalg.matrix4_inverse(bone.inverse_bind_matrix)
      bone_socket_transform = skinning_matrix * bind_matrix
      has_bone_socket = true
    }
    if entry.parent_is_dirty || is_dirty || has_bone_socket {
      if entry.handle != world.root {
        world.octree_dirty_set[entry.handle] = true
      }
      // Bone socket provides an additional transform layer between parent and local
      // transform_update_world will multiply: (parent * bone_socket) * local_matrix
      transform_update_world(
        &current_node.transform,
        entry.parent_transform * bone_socket_transform,
      )
      if rm != nil {
        resources.node_upload_transform(
          rm,
          entry.handle,
          &current_node.transform.world_matrix,
        )
      }
    }
    if (visibility_changed || is_dirty || entry.parent_is_dirty) && rm != nil {
      data := resources.NodeData {
        material_id           = 0xFFFFFFFF,
        mesh_id               = 0xFFFFFFFF,
        attachment_data_index = 0xFFFFFFFF,
      }
      if mesh_attachment, has_mesh := current_node.attachment.(MeshAttachment);
         has_mesh {
        data.material_id = mesh_attachment.material.index
        data.mesh_id = mesh_attachment.handle.index
        if current_node.visible && current_node.parent_visible {
          data.flags |= resources.NodeFlagSet{.VISIBLE}
        }
        if current_node.culling_enabled {
          data.flags |= {.CULLING_ENABLED}
        }
        if mesh_attachment.cast_shadow {
          data.flags |= resources.NodeFlagSet{.CASTS_SHADOW}
        }
        if material_entry, has_material := cont.get(
          rm.materials,
          mesh_attachment.material,
        ); has_material {
          switch material_entry.type {
          case .TRANSPARENT:
            data.flags |= resources.NodeFlagSet{.MATERIAL_TRANSPARENT}
          case .WIREFRAME:
            data.flags |= resources.NodeFlagSet{.MATERIAL_WIREFRAME}
          case .PBR, .UNLIT:
          // No additional flags needed
          }
        }
        if skinning, has_skinning := mesh_attachment.skinning.?; has_skinning {
          data.attachment_data_index = skinning.bone_matrix_buffer_offset
        }
      }
      if sprite_attachment, has_sprite := current_node.attachment.(SpriteAttachment);
         has_sprite {
        _apply_sprite_to_node_data(&data, sprite_attachment, current_node, rm)
      }
      resources.node_upload_data(rm, entry.handle, &data)
    }
    if callback != nil && current_node.parent_visible && current_node.visible {
      if !callback(current_node, cb_context) do continue
    }
    children_copy := make([]resources.Handle, len(current_node.children))
    defer delete(children_copy)
    copy(children_copy, current_node.children[:])
    for child_handle in children_copy {
      append(
        &world.traversal_stack,
        TraverseEntry {
          child_handle,
          current_node.transform.world_matrix,
          is_dirty || entry.parent_is_dirty,
          current_node.parent_visible && current_node.visible,
        },
      )
    }
  }
  return true
}

@(private)
assign_emitter_to_node :: proc(
  rm: ^resources.Manager,
  node_handle: resources.Handle,
  node: ^Node,
) {
  if rm == nil {
    return
  }
  attachment, is_emitter := &node.attachment.(EmitterAttachment)
  if !is_emitter {
    return
  }
  emitter, ok := cont.get(rm.emitters, attachment.handle)
  if ok {
    emitter.node_handle = node_handle
    resources.emitter_write_to_gpu(rm, attachment.handle, emitter)
  }
}

@(private)
assign_forcefield_to_node :: proc(
  rm: ^resources.Manager,
  node_handle: resources.Handle,
  node: ^Node,
) {
  if rm == nil {
    return
  }
  attachment, is_forcefield := &node.attachment.(ForceFieldAttachment)
  if !is_forcefield {
    return
  }
  forcefield, ok := cont.get(rm.forcefields, attachment.handle)
  if ok {
    forcefield.node_handle = node_handle
    resources.forcefield_write_to_gpu(rm, attachment.handle, forcefield)
  }
}

@(private)
assign_light_to_node :: proc(
  rm: ^resources.Manager,
  node_handle: resources.Handle,
  node: ^Node,
) {
  if rm == nil {
    return
  }
  attachment, is_light := &node.attachment.(LightAttachment)
  if !is_light {
    return
  }
  if light, ok := cont.get(rm.lights, attachment.handle); ok {
    light.node_handle = node_handle
    light.node_index = node_handle.index
    gpu.write(&rm.lights_buffer, &light.data, int(attachment.handle.index))
  }
}

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

node_handle_translate_by :: proc(
  world: ^World,
  handle: resources.Handle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_translate_by(&node.transform, x, y, z)
  }
}

node_handle_translate :: proc(
  world: ^World,
  handle: resources.Handle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_translate(&node.transform, x, y, z)
  }
}

node_handle_rotate_by :: proc {
  node_handle_rotate_by_quaternion,
  node_handle_rotate_by_angle,
}

node_handle_rotate_by_quaternion :: proc(
  world: ^World,
  handle: resources.Handle,
  q: quaternion128,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_rotate_by_quaternion(&node.transform, q)
  }
}

node_handle_rotate_by_angle :: proc(
  world: ^World,
  handle: resources.Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_rotate_by_angle(&node.transform, angle, axis)
  }
}

node_handle_rotate :: proc {
  node_handle_rotate_quaternion,
  node_handle_rotate_angle,
}

node_handle_rotate_quaternion :: proc(
  world: ^World,
  handle: resources.Handle,
  q: quaternion128,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_rotate_quaternion(&node.transform, q)
  }
}

node_handle_rotate_angle :: proc(
  world: ^World,
  handle: resources.Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_rotate_angle(&node.transform, angle, axis)
  }
}

node_handle_scale_xyz_by :: proc(
  world: ^World,
  handle: resources.Handle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_scale_xyz_by(&node.transform, x, y, z)
  }
}

node_handle_scale_by :: proc(world: ^World, handle: resources.Handle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_scale_by(&node.transform, s)
  }
}

node_handle_scale_xyz :: proc(
  world: ^World,
  handle: resources.Handle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_scale_xyz(&node.transform, x, y, z)
  }
}

node_handle_scale :: proc(world: ^World, handle: resources.Handle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.transform_scale(&node.transform, s)
  }
}

create_point_light_attachment :: proc(
  node_handle: resources.Handle,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: b32 = true,
) -> (
  attachment: LightAttachment,
  ok: bool,
) #optional_ok {
  handle: resources.Handle
  handle, ok = resources.create_light(
    rm,
    gctx,
    .POINT,
    node_handle,
    color,
    radius,
    cast_shadow = cast_shadow,
  )
  attachment = LightAttachment{handle}
  return
}

create_directional_light_attachment :: proc(
  node_handle: resources.Handle,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  cast_shadow: b32 = false,
) -> (
  attachment: LightAttachment,
  ok: bool,
) #optional_ok {
  handle: resources.Handle
  handle, ok = resources.create_light(
    rm,
    gctx,
    .DIRECTIONAL,
    node_handle,
    color,
    cast_shadow = cast_shadow,
  )
  attachment = LightAttachment{handle}
  return
}

create_spot_light_attachment :: proc(
  node_handle: resources.Handle,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> (
  attachment: LightAttachment,
  ok: bool,
) #optional_ok {
  angle_inner := angle * 0.8
  angle_outer := angle
  handle: resources.Handle
  handle, ok = resources.create_light(
    rm,
    gctx,
    .SPOT,
    node_handle,
    color,
    radius,
    angle_inner,
    angle_outer,
    cast_shadow,
  )
  attachment = LightAttachment{handle}
  return
}

create_sprite_attachment :: proc(
  rm: ^resources.Manager,
  shared_quad_mesh: resources.Handle,
  texture: resources.Handle,
  material: resources.Handle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  frame_index: u32 = 0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  sampler: resources.SamplerType = .NEAREST_REPEAT,
  animation: Maybe(resources.SpriteAnimation) = nil,
) -> (
  attachment: SpriteAttachment,
  ok: bool,
) #optional_ok {
  sprite_handle: resources.Handle
  sprite_handle, ok = resources.create_sprite(
    rm,
    texture,
    frame_columns,
    frame_rows,
    frame_index,
    color,
    sampler,
    animation,
  )
  if !ok do return {}, false
  attachment = SpriteAttachment {
    sprite_handle = sprite_handle,
    mesh_handle   = shared_quad_mesh,
    material      = material,
  }
  return attachment, true
}

@(private)
_ensure_actor_pool :: proc(world: ^World, $T: typeid) -> ^ActorPool(T) {
  tid := typeid_of(T)
  entry, exists := &world.actor_pools[tid]
  if exists {
    return auto_cast entry.pool_ptr
  }
  pool := new(ActorPool(T))
  actor_pool_init(pool)
  world.actor_pools[tid] = ActorPoolEntry {
    pool_ptr = rawptr(pool),
    tick_fn = proc(pool_ptr: rawptr, ctx: ^ActorContext) {
      actor_pool_tick(cast(^ActorPool(T))pool_ptr, ctx)
    },
    alloc_fn = proc(
      pool_ptr: rawptr,
      node_handle: resources.Handle,
    ) -> (
      resources.Handle,
      rawptr,
      bool,
    ) {
      return actor_alloc(cast(^ActorPool(T))pool_ptr, node_handle)
    },
    get_fn = proc(
      pool_ptr: rawptr,
      handle: resources.Handle,
    ) -> (
      rawptr,
      bool,
    ) {
      return actor_get(cast(^ActorPool(T))pool_ptr, handle)
    },
    free_fn = proc(pool_ptr: rawptr, handle: resources.Handle) -> bool {
      _, freed := actor_free(cast(^ActorPool(T))pool_ptr, handle)
      return freed
    },
    destroy_fn = proc(pool_ptr: rawptr) {
      p := cast(^ActorPool(T))pool_ptr
      actor_pool_destroy(p)
      free(p)
    },
  }
  return pool
}

spawn_actor :: proc(
  world: ^World,
  $T: typeid,
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  actor_handle: resources.Handle,
  actor: ^Actor(T),
  ok: bool,
) {
  node_handle, _, node_ok := spawn(world, attachment, rm)
  if !node_ok do return {}, nil, false
  pool := _ensure_actor_pool(world, T)
  return actor_alloc(pool, node_handle)
}

spawn_actor_at :: proc(
  world: ^World,
  $T: typeid,
  position: [3]f32,
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  actor_handle: resources.Handle,
  actor: ^Actor(T),
  ok: bool,
) {
  node_handle, _, node_ok := spawn_at(world, position, attachment, rm)
  if !node_ok do return {}, nil, false
  pool := _ensure_actor_pool(world, T)
  return actor_alloc(pool, node_handle)
}

spawn_actor_child :: proc(
  world: ^World,
  $T: typeid,
  parent: resources.Handle,
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  actor_handle: resources.Handle,
  actor: ^Actor(T),
  ok: bool,
) {
  node_handle, _, node_ok := spawn_child(world, parent, attachment, rm)
  if !node_ok do return {}, nil, false
  pool := _ensure_actor_pool(world, T)
  return actor_alloc(pool, node_handle)
}

get_actor :: proc(
  world: ^World,
  $T: typeid,
  handle: resources.Handle,
) -> (
  actor: ^Actor(T),
  ok: bool,
) #optional_ok {
  entry, pool_exists := world.actor_pools[typeid_of(T)]
  if !pool_exists do return nil, false
  actor_ptr, found := entry.get_fn(entry.pool_ptr, handle)
  if !found do return nil, false
  return cast(^Actor(T))actor_ptr, true
}

free_actor :: proc(
  world: ^World,
  $T: typeid,
  handle: resources.Handle,
) -> bool {
  entry, pool_exists := world.actor_pools[typeid_of(T)]
  if !pool_exists do return false
  return entry.free_fn(entry.pool_ptr, handle)
}

enable_actor_tick :: proc(
  world: ^World,
  $T: typeid,
  handle: resources.Handle,
) {
  pool := _ensure_actor_pool(world, T)
  actor_enable_tick(pool, handle)
}

disable_actor_tick :: proc(
  world: ^World,
  $T: typeid,
  handle: resources.Handle,
) {
  entry, pool_exists := world.actor_pools[typeid_of(T)]
  if !pool_exists do return
  pool := cast(^ActorPool(T))entry.pool_ptr
  actor_disable_tick(pool, handle)
}

world_tick_actors :: proc(
  world: ^World,
  rm: ^resources.Manager,
  delta_time: f32,
  game_state: rawptr = nil,
) {
  ctx := ActorContext {
    world      = world,
    rm         = rm,
    delta_time = delta_time,
    game_state = game_state,
  }
  for t, entry in world.actor_pools {
    entry.tick_fn(entry.pool_ptr, &ctx)
  }
}

world_tick_actor :: proc(world: ^World, $T: typeid, handle: resources.Handle) {
  entry, pool_exists := world.actor_pools[typeid_of(T)]
  if !pool_exists do return
}
