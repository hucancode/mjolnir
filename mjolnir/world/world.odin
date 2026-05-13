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

// Boundary accessors. Keep `containers` invisible to user code by going through these.
node :: proc(w: ^World, h: NodeHandle) -> (^Node, bool) #optional_ok {
  return cont.get(w.nodes, h)
}

mesh :: proc(w: ^World, h: MeshHandle) -> (^Mesh, bool) #optional_ok {
  return cont.get(w.meshes, h)
}

material :: proc(w: ^World, h: MaterialHandle) -> (^Material, bool) #optional_ok {
  return cont.get(w.materials, h)
}

camera :: proc(w: ^World, h: CameraHandle) -> (^Camera, bool) #optional_ok {
  return cont.get(w.cameras, h)
}

clip :: proc(w: ^World, h: ClipHandle) -> (^anim.Clip, bool) #optional_ok {
  return cont.get(w.animation_clips, h)
}

emitter :: proc(w: ^World, h: EmitterHandle) -> (^Emitter, bool) #optional_ok {
  return cont.get(w.emitters, h)
}

forcefield :: proc(w: ^World, h: ForceFieldHandle) -> (^ForceField, bool) #optional_ok {
  return cont.get(w.forcefields, h)
}

sprite :: proc(w: ^World, h: SpriteHandle) -> (^Sprite, bool) #optional_ok {
  return cont.get(w.sprites, h)
}

// Add tags to a node by handle. Returns false if node not found.
tag_node :: proc(
  world: ^World,
  handle: NodeHandle,
  tags: NodeTagSet,
) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags += tags
  return true
}

// Remove tags from a node. Returns false if node not found.
untag_node :: proc(
  world: ^World,
  handle: NodeHandle,
  tags: NodeTagSet,
) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags -= tags
  return true
}

tag   :: tag_node
untag :: untag_node

// Typed attachment accessors. Skip the .(T) match boilerplate at callsites.
point_light :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^PointLightAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(PointLightAttachment)
  return
}

directional_light :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^DirectionalLightAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(DirectionalLightAttachment)
  return
}

spot_light :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^SpotLightAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(SpotLightAttachment)
  return
}

mesh_attachment :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^MeshAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(MeshAttachment)
  return
}

emitter_attachment :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^EmitterAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(EmitterAttachment)
  return
}

forcefield_attachment :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^ForceFieldAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(ForceFieldAttachment)
  return
}

sprite_attachment :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^SpriteAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(SpriteAttachment)
  return
}

rigid_body_attachment :: proc(
  w: ^World,
  h: NodeHandle,
) -> (att: ^RigidBodyAttachment, ok: bool) #optional_ok {
  n := cont.get(w.nodes, h) or_return
  att, ok = &n.attachment.(RigidBodyAttachment)
  return
}

// AnimationInstance represents a playing animation clip on a node
// Uses handle-based lookup to avoid pointer invalidation when pools resize
AnimationInstance :: struct {
  clip_handle: ClipHandle, // handle to animation clip (resolved at runtime)
  mode:        anim.PlayMode,
  status:      anim.Status,
  time:        f32,
  speed:       f32,
}

Node :: struct {
  parent:          NodeHandle,
  children:        [dynamic]NodeHandle,
  transform:       geometry.Transform,
  name:            string,
  bone_socket:     string, // if not empty, attach to this bone on parent skinned mesh
  attachment:      NodeAttachment,
  animation:       Maybe(AnimationInstance),
  culling_enabled: bool,
  visible:         bool, // node's own visibility state
  parent_visible:  bool, // visibility inherited from parent chain
  tags:            NodeTagSet, // tags for queries and filtering
}

TraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

TraverseEntry :: struct {
  handle:            NodeHandle,
  parent_transform:  matrix[4, 4]f32,
  parent_is_dirty:   bool,
  parent_is_visible: bool,
}

World :: struct {
  root:               NodeHandle,
  nodes:              Pool(Node),
  traversal_stack:    [dynamic]TraverseEntry,
  staging:            StagingList,
  animatable_nodes:   [dynamic]NodeHandle,
  // CPU resource pools (moved from resources.Manager)
  meshes:             cont.Pool(Mesh),
  materials:          cont.Pool(Material),
  cameras:            cont.Pool(Camera),
  main_camera:        CameraHandle,
  emitters:           cont.Pool(Emitter),
  forcefields:        cont.Pool(ForceField),
  sprites:            cont.Pool(Sprite),
  animation_clips:    cont.Pool(anim.Clip),
  // Active resource tracking
  active_light_nodes: [dynamic]NodeHandle,
  // Builtin resources
  builtin_materials:  [len(Color)]MaterialHandle,
  builtin_meshes:     [len(Primitive)]MeshHandle,
  // Camera controllers
  orbit_controller:   CameraController,
  free_controller:    CameraController,
  active_controller:  ^CameraController,
}

node_init :: proc(self: ^Node, name: string = "") {
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.bone_socket = ""
  self.culling_enabled = true
  self.visible = true
  self.parent_visible = true
  self.tags = {}
}

node_destroy :: proc(
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
  node_init(node)
  node.attachment = attachment
  assign_emitter_to_node(self, handle, node)
  assign_forcefield_to_node(self, handle, node)
  node.transform.position = position
  node.transform.is_dirty = true
  attach(self.nodes, parent, handle)
  stage_node_data(&self.staging, handle)
  return handle, true
}

init :: proc(world: ^World) -> bool {
  cont.init(&world.nodes, MAX_NODES_IN_SCENE)
  staging_init(&world.staging)
  root: ^Node
  world.root, root, _ = cont.alloc(&world.nodes, NodeHandle)
  node_init(root, "root")
  root.parent = world.root

  cont.init(&world.meshes, MAX_MESHES)
  cont.init(&world.materials, MAX_MATERIALS)
  cont.init(&world.cameras, MAX_ACTIVE_CAMERAS)
  cont.init(&world.emitters, MAX_EMITTERS)
  cont.init(&world.forcefields, MAX_FORCE_FIELDS)
  cont.init(&world.sprites, MAX_SPRITES)
  cont.init(&world.animation_clips, 0)

  init_builtin_materials(world)
  init_builtin_meshes(world)

  log.info("World resource pools initialized")
  return true
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
  cont.destroy(world.cameras, proc(_: ^Camera) {})
  cont.destroy(world.meshes, mesh_destroy)
  cont.destroy(world.materials, proc(_: ^Material) {})
  cont.destroy(world.emitters, proc(_: ^Emitter) {})
  cont.destroy(world.forcefields, proc(_: ^ForceField) {})
  cont.destroy(world.sprites, proc(_: ^Sprite) {})
  cont.destroy(world.animation_clips, anim.clip_destroy)

  // Nodes need handle to destroy attachments — iterate manually
  for &entry, i in world.nodes.entries {
    if entry.active {
      handle := NodeHandle {
        index      = u32(i),
        generation = entry.generation,
      }
      node_destroy(&entry.item, world, handle)
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
  if node == nil do return false
  detach(world.nodes, handle)
  despawn_subtree(world, handle, node)
  return true
}

// Internal: free a node and its descendants without touching the parent's
// children array. Caller must have already detached `handle` from its parent.
// Skipping the per-child detach is what makes bulk despawn O(N) instead of
// O(N^2) — every linear_search through a huge children array is avoided.
@(private)
despawn_subtree :: proc(world: ^World, handle: NodeHandle, node: ^Node) {
  for child_handle in node.children {
    child_node := cont.get(world.nodes, child_handle) or_continue
    despawn_subtree(world, child_handle, child_node)
  }
  stage_node_data(&world.staging, handle)
  unregister_animatable_node(world, handle)
  if freed_node, ok := cont.free(&world.nodes, handle); ok {
    node_destroy(freed_node, world, handle)
    freed_node^ = {}
  }
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

// Mark dirty wrappers. Hide staging detail from gameplay code.
mark_light_dirty      :: proc(w: ^World, h: NodeHandle)   { stage_light_data(&w.staging, h) }
mark_node_dirty       :: proc(w: ^World, h: NodeHandle)   { stage_node_data(&w.staging, h) }
mark_camera_dirty     :: proc(w: ^World, h: CameraHandle) { stage_camera_data(&w.staging, h) }

// Light field setters. Mutate + auto-stage. No-op when value unchanged so
// per-frame UI bindings don't churn the dirty queue.
set_light_color :: proc(w: ^World, h: NodeHandle, color: [4]f32) {
  n, n_ok := cont.get(w.nodes, h)
  if !n_ok do return
  target: ^[4]f32
  switch &a in n.attachment {
  case PointLightAttachment:       target = &a.color
  case DirectionalLightAttachment: target = &a.color
  case SpotLightAttachment:        target = &a.color
  case MeshAttachment, EmitterAttachment, ForceFieldAttachment,
       SpriteAttachment, RigidBodyAttachment:
    return
  case:
    return
  }
  if target^ == color do return
  target^ = color
  stage_light_data(&w.staging, h)
}

set_light_intensity :: proc(w: ^World, h: NodeHandle, intensity: f32) {
  n, n_ok := cont.get(w.nodes, h)
  if !n_ok do return
  target: ^f32
  switch &a in n.attachment {
  case PointLightAttachment:       target = &a.color[3]
  case DirectionalLightAttachment: target = &a.color[3]
  case SpotLightAttachment:        target = &a.color[3]
  case MeshAttachment, EmitterAttachment, ForceFieldAttachment,
       SpriteAttachment, RigidBodyAttachment:
    return
  case:
    return
  }
  if target^ == intensity do return
  target^ = intensity
  stage_light_data(&w.staging, h)
}

set_light_radius :: proc(w: ^World, h: NodeHandle, radius: f32) {
  n, n_ok := cont.get(w.nodes, h)
  if !n_ok do return
  target: ^f32
  switch &a in n.attachment {
  case PointLightAttachment: target = &a.radius
  case SpotLightAttachment:  target = &a.radius
  case DirectionalLightAttachment, MeshAttachment, EmitterAttachment,
       ForceFieldAttachment, SpriteAttachment, RigidBodyAttachment:
    return
  case:
    return
  }
  if target^ == radius do return
  target^ = radius
  stage_light_data(&w.staging, h)
}

// Mesh attachment setters. Mutate + auto-stage. Leave sibling fields untouched.
set_mesh_handle :: proc(w: ^World, h: NodeHandle, mesh: MeshHandle) {
  n, n_ok := cont.get(w.nodes, h)
  if !n_ok do return
  a, a_ok := &n.attachment.(MeshAttachment)
  if !a_ok do return
  if a.handle == mesh do return
  a.handle = mesh
  stage_node_data(&w.staging, h)
}

set_material_handle :: proc(w: ^World, h: NodeHandle, material: MaterialHandle) {
  n, n_ok := cont.get(w.nodes, h)
  if !n_ok do return
  a, a_ok := &n.attachment.(MeshAttachment)
  if !a_ok do return
  if a.material == material do return
  a.material = material
  stage_node_data(&w.staging, h)
}

// Sync all nodes with rigid body attachments from physics to world
sync_all_physics_to_world :: proc(
  world: ^World,
  physics_world: ^physics.World,
) {
  for &entry in world.nodes.entries do if entry.active {
    node := &entry.item
    if attachment, ok := node.attachment.(RigidBodyAttachment); ok {
      if body, ok := physics.get_dynamic_body(physics_world, attachment.body_handle); ok {
        node.transform.position = body.position
        node.transform.rotation = body.rotation
        node.transform.is_dirty = true
      }
    }
  }
}
