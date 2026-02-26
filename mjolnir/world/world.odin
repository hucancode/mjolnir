package world

import anim "../animation"
import cont "../containers"
import "../geometry"
import physics "../physics"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:sync"

PointLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // range
  cast_shadow: bool,
}

DirectionalLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // shadow projection radius
  cast_shadow: bool,
}

SpotLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // range
  angle_inner: f32, // inner cone angle
  angle_outer: f32, // outer cone angle
  cast_shadow: bool,
}

NodeSkinning :: struct {
  layers:            [dynamic]anim.Layer, // Animation layers (FK + IK)
  active_transition: Maybe(anim.Transition), // Active transition state
  matrices:          []matrix[4, 4]f32, // Latest computed skinning matrices
}

MeshAttachment :: struct {
  handle:      MeshHandle,
  material:    MaterialHandle,
  skinning:    Maybe(NodeSkinning),
  cast_shadow: bool,
}

EmitterAttachment :: struct {
  handle: EmitterHandle,
}

ForceFieldAttachment :: struct {
  handle: ForceFieldHandle,
}

SpriteAttachment :: struct {
  sprite_handle: SpriteHandle,
  mesh_handle:   MeshHandle,
  material:      MaterialHandle,
}

RigidBodyAttachment :: struct {
  body_handle: physics.DynamicRigidBodyHandle,
}

NodeAttachment :: union {
  PointLightAttachment,
  DirectionalLightAttachment,
  SpotLightAttachment,
  MeshAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
  SpriteAttachment,
  RigidBodyAttachment,
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
  ENVIRONMENT, // static environment mesh (walls, floors, etc.)
}

NodeTagSet :: bit_set[NodeTag;u32]

// AnimationInstance represents a playing animation clip on a node
// Uses handle-based lookup to avoid pointer invalidation when pools resize
AnimationInstance :: struct {
  clip_handle: ClipHandle, // handle to animation clip (resolved at runtime)
  mode:        anim.PlayMode,
  status:      anim.Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

Node :: struct {
  parent:           NodeHandle,
  children:         [dynamic]NodeHandle,
  transform:        geometry.Transform,
  name:             string,
  bone_socket:      string, // if not empty, attach to this bone on parent skinned mesh
  attachment:       NodeAttachment,
  animation:        Maybe(AnimationInstance),
  culling_enabled:  bool,
  visible:          bool, // node's own visibility state
  parent_visible:   bool, // visibility inherited from parent chain
  tags:             NodeTagSet, // tags for queries and filtering
}

TraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

TraverseEntry :: struct {
  handle:            NodeHandle,
  parent_transform:  matrix[4, 4]f32,
  parent_is_dirty:   bool,
  parent_is_visible: bool,
}

// Debug draw callbacks - engine can set these to enable debug visualization
DebugDrawLineStripCallback :: proc(
  points: []geometry.Vertex,
  duration_seconds: f64,
  color: [4]f32,
  bypass_depth: bool,
)
DebugDrawMeshCallback :: proc(
  mesh_handle: MeshHandle,
  transform: matrix[4, 4]f32,
  duration_seconds: f64,
  color: [4]f32,
  bypass_depth: bool,
)

World :: struct {
  root:                    NodeHandle,
  nodes:                   Pool(Node),
  traversal_stack:         [dynamic]TraverseEntry,
  staging:                 StagingList,
  animatable_nodes:        [dynamic]NodeHandle,
  // CPU resource pools (moved from resources.Manager)
  meshes:                  cont.Pool(Mesh),
  materials:               cont.Pool(Material),
  cameras:                 cont.Pool(Camera),
  main_camera:             CameraHandle,
  emitters:                cont.Pool(Emitter),
  forcefields:             cont.Pool(ForceField),
  sprites:                 cont.Pool(Sprite),
  animation_clips:         cont.Pool(anim.Clip),
  // Active resource tracking
  active_light_nodes:      [dynamic]NodeHandle,
  // Builtin resources
  builtin_materials:       [len(Color)]MaterialHandle,
  builtin_meshes:          [len(Primitive)]MeshHandle,
  // Camera controllers
  orbit_controller:        CameraController,
  free_controller:         CameraController,
  active_controller:       ^CameraController,
}

init_node :: proc(self: ^Node, name: string = "") {
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.bone_socket = ""
  self.culling_enabled = true
  self.visible = true
  self.parent_visible = true
  self.tags = {}
}

update_node_tags :: proc(node: ^Node) {
  #partial switch _ in node.attachment {
  case MeshAttachment:
    node.tags |= {.MESH}
  case SpriteAttachment:
    node.tags |= {.SPRITE}
  case PointLightAttachment, DirectionalLightAttachment, SpotLightAttachment:
    node.tags |= {.LIGHT}
  case EmitterAttachment:
    node.tags |= {.EMITTER}
  case ForceFieldAttachment:
    node.tags |= {.FORCEFIELD}
  }
  if node.visible && node.parent_visible {
    node.tags |= {.VISIBLE}
  } else {
    node.tags -= {.VISIBLE}
  }
}

destroy_node :: proc(
  self: ^Node,
  world: ^World = nil,
  node_handle: NodeHandle = {},
) {
  delete(self.children)
  self.children = {}
  if world == nil {
    return
  }
  #partial switch &attachment in &self.attachment {
  case PointLightAttachment:
    unregister_active_light(world, node_handle)
  case DirectionalLightAttachment:
    unregister_active_light(world, node_handle)
  case SpotLightAttachment:
    unregister_active_light(world, node_handle)
  case EmitterAttachment:
    destroy_emitter(world, attachment.handle)
    attachment.handle = {}
  case ForceFieldAttachment:
    destroy_forcefield(world, attachment.handle)
    attachment.handle = {}
  case SpriteAttachment:
    destroy_sprite(world, attachment.sprite_handle)
    attachment.sprite_handle = {}
  case MeshAttachment:
    skinning, has_skin := &attachment.skinning.?
    if has_skin {
      delete(skinning.layers)
    }
  }
}

detach :: proc(nodes: Pool(Node), child_handle: NodeHandle) {
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

attach :: proc(nodes: Pool(Node), parent_handle, child_handle: NodeHandle) {
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

spawn :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  attachment: NodeAttachment = nil,
) -> (
  handle: NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_child(self, self.root, position, attachment)
}

spawn_child :: proc(
  self: ^World,
  parent: NodeHandle,
  position: [3]f32 = {0, 0, 0},
  attachment: NodeAttachment = nil,
) -> (
  handle: NodeHandle,
  ok: bool,
) #optional_ok {
  node: ^Node
  handle, node = cont.alloc(&self.nodes, NodeHandle) or_return
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(self, handle, node)
  assign_forcefield_to_node(self, handle, node)
  assign_light_to_node(self, handle, node)
  update_node_tags(node)
  node.transform.position = position
  node.transform.is_dirty = true
  attach(self.nodes, parent, handle)
  stage_node_data(&self.staging, handle)
  return handle, true
}

init :: proc(world: ^World) {
  // Scene graph
  cont.init(&world.nodes, MAX_NODES_IN_SCENE)
  staging_init(&world.staging)
  root: ^Node
  world.root, root, _ = cont.alloc(&world.nodes, NodeHandle)
  init_node(root, "root")
  root.parent = world.root

  // Resource pools
  cont.init(&world.meshes, MAX_MESHES)
  cont.init(&world.materials, MAX_MATERIALS)
  cont.init(&world.cameras, MAX_ACTIVE_CAMERAS)
  cont.init(&world.emitters, MAX_EMITTERS)
  cont.init(&world.forcefields, MAX_FORCE_FIELDS)
  cont.init(&world.sprites, MAX_SPRITES)
  cont.init(&world.animation_clips, 0)

  // Initialize builtin resources
  init_builtin_materials(world)
  init_builtin_meshes(world)

  log.info("World resource pools initialized")
}


register_animatable_node :: proc(world: ^World, handle: NodeHandle) {
  // TODO: if this list get more than 10000 items, we need to use a map
  if slice.contains(world.animatable_nodes[:], handle) do return
  append(&world.animatable_nodes, handle)
}

unregister_animatable_node :: proc(world: ^World, handle: NodeHandle) {
  if i, found := slice.linear_search(world.animatable_nodes[:], handle);
     found {
    unordered_remove(&world.animatable_nodes, i)
  }
}

begin_frame :: proc(
  world: ^World,
  delta_time: f32 = 0.016,
  game_state: rawptr = nil,
) {
  traverse(world)
}

shutdown :: proc(world: ^World) {
  delete(world.cameras.entries)
  delete(world.cameras.free_indices)

  // Clean up meshes
  for &entry in world.meshes.entries {
    if entry.generation > 0 && entry.active {
      mesh_destroy(&entry.item)
    }
  }
  delete(world.meshes.entries)
  delete(world.meshes.free_indices)

  // Clean up materials
  delete(world.materials.entries)
  delete(world.materials.free_indices)

  // Clean up emitters
  delete(world.emitters.entries)
  delete(world.emitters.free_indices)

  // Clean up forcefields
  delete(world.forcefields.entries)
  delete(world.forcefields.free_indices)

  // Clean up sprites
  delete(world.sprites.entries)
  delete(world.sprites.free_indices)

  // Clean up animation clips
  for &entry in world.animation_clips.entries {
    if entry.generation > 0 && entry.active {
      anim.clip_destroy(&entry.item)
    }
  }
  delete(world.animation_clips.entries)
  delete(world.animation_clips.free_indices)

  // Clean up nodes
  for &entry, i in world.nodes.entries {
    if entry.active {
      handle := NodeHandle {
        index      = u32(i),
        generation = entry.generation,
      }
      destroy_node(&entry.item, world, handle)
    }
  }
  cont.destroy(world.nodes, proc(node: ^Node) {})
  delete(world.traversal_stack)
  delete(world.active_light_nodes)
  delete(world.animatable_nodes)
  staging_destroy(&world.staging)
}

// Despawn a node and all its children recursively.
// The node is staged for GPU cleanup and freed immediately.
// Engine's sync will detect the nil node and release GPU resources.
despawn :: proc(world: ^World, handle: NodeHandle) -> bool {
  node := cont.get(world.nodes, handle)
  if node == nil {
    log.warnf("despawn: node %v not found (already freed or invalid)", handle)
    return false
  }

  log.infof("despawn: freeing node %v '%s' and %d children", handle, node.name, len(node.children))

  // Recursively despawn all children FIRST (bottom-up cleanup)
  // Make a copy since we'll modify the children array during iteration
  children_copy := make([dynamic]NodeHandle, len(node.children), context.temp_allocator)
  copy(children_copy[:], node.children[:])
  for child_handle in children_copy {
    despawn(world, child_handle)
  }

  // Detach from parent (removes self from parent's children array)
  detach(world.nodes, handle)

  // Stage for GPU cleanup - Engine will detect nil and trigger Render cleanup
  stage_node_data(&world.staging, handle)

  // Unregister from tracking lists
  unregister_animatable_node(world, handle)

  // Free immediately
  if freed_node, ok := cont.free(&world.nodes, handle); ok {
    destroy_node(freed_node, world, handle)
    // Clear the node struct to prevent use-after-free
    freed_node^ = {}
  }

  return true
}

traverse :: proc(world: ^World) -> bool {
  append(
    &world.traversal_stack,
    TraverseEntry{world.root, linalg.MATRIX4F32_IDENTITY, false, true},
  )
  for len(world.traversal_stack) > 0 {
    entry := pop(&world.traversal_stack)
    current_node := cont.get(world.nodes, entry.handle) or_continue
    visibility_changed :=
      current_node.parent_visible != entry.parent_is_visible
    current_node.parent_visible = entry.parent_is_visible
    is_dirty := geometry.update_local(&current_node.transform)
    if visibility_changed {
      update_node_tags(current_node)
    }
    bone_socket_transform := linalg.MATRIX4F32_IDENTITY
    has_bone_socket := false
    apply_bone_socket: {
      if current_node.bone_socket == "" do break apply_bone_socket
      parent_node := cont.get(world.nodes, current_node.parent) or_break
      parent_mesh_attachment := parent_node.attachment.(MeshAttachment) or_break
      parent_mesh := cont.get(
        world.meshes,
        parent_mesh_attachment.handle,
      ) or_break
      bone_index := find_bone_by_name(
        parent_mesh,
        current_node.bone_socket,
      ) or_break
      parent_skinning := parent_mesh_attachment.skinning.? or_break
      parent_mesh_skinning := parent_mesh.skinning.? or_break
      if bone_index >= u32(len(parent_mesh_skinning.bones)) do break apply_bone_socket
      if bone_index >= u32(len(parent_skinning.matrices)) do break apply_bone_socket
      // Stored matrices are skinning matrices (world_transform * inverse_bind).
      // To recover bone world transform, multiply by bind matrix.
      skinning_matrix := parent_skinning.matrices[bone_index]
      bone := parent_mesh_skinning.bones[bone_index]
      bind_matrix := linalg.matrix4_inverse(bone.inverse_bind_matrix)
      bone_socket_transform = skinning_matrix * bind_matrix
      has_bone_socket = true
    }
    if entry.parent_is_dirty || is_dirty || has_bone_socket {
      // Bone socket provides an additional transform layer between parent and local
      // transform_update_world will multiply: (parent * bone_socket) * local_matrix
      geometry.update_world(
        &current_node.transform,
        entry.parent_transform * bone_socket_transform,
      )
      #partial switch _ in current_node.attachment {
      case PointLightAttachment,
           DirectionalLightAttachment,
           SpotLightAttachment:
        stage_light_data(&world.staging, entry.handle)
      }
    }
    if visibility_changed || is_dirty || entry.parent_is_dirty {
      stage_node_data(&world.staging, entry.handle)
    }
    for child_handle in current_node.children {
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
  world: ^World,
  node_handle: NodeHandle,
  node: ^Node,
) {
  attachment, is_emitter := &node.attachment.(EmitterAttachment)
  if !is_emitter {
    return
  }
  emitter, ok := cont.get(world.emitters, attachment.handle)
  if ok {
    emitter.node_handle = node_handle
    stage_emitter_data(&world.staging, attachment.handle)
  }
}

@(private)
assign_forcefield_to_node :: proc(
  world: ^World,
  node_handle: NodeHandle,
  node: ^Node,
) {
  attachment, is_forcefield := &node.attachment.(ForceFieldAttachment)
  if !is_forcefield {
    return
  }
  forcefield, ok := cont.get(world.forcefields, attachment.handle)
  if ok {
    forcefield.node_handle = node_handle
    stage_forcefield_data(&world.staging, attachment.handle)
  }
}

@(private)
assign_light_to_node :: proc(
  world: ^World,
  node_handle: NodeHandle,
  node: ^Node,
) {
  #partial switch _ in node.attachment {
  case PointLightAttachment, DirectionalLightAttachment, SpotLightAttachment:
    register_active_light(world, node_handle)
  }
}

create_point_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> (
  attachment: PointLightAttachment,
) {
  return PointLightAttachment {
    color = color,
    radius = radius,
    cast_shadow = cast_shadow,
  }
}

create_directional_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> (
  attachment: DirectionalLightAttachment,
) {
  return DirectionalLightAttachment {
    color = color,
    radius = radius,
    cast_shadow = cast_shadow,
  }
}

create_spot_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: bool = true,
) -> (
  attachment: SpotLightAttachment,
) {
  angle_inner := angle * 0.8
  angle_outer := angle
  return SpotLightAttachment {
    color = color,
    radius = radius,
    angle_inner = angle_inner,
    angle_outer = angle_outer,
    cast_shadow = cast_shadow,
  }
}
