package world

import anim "../animation"
import cont "../containers"
import "../geometry"
import "../gpu"
import physics "../physics"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:sync"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)

LightAttachment :: struct {
  handle: resources.LightHandle,
}

NodeSkinning :: struct {
  layers:                    [dynamic]anim.Layer, // Animation layers (FK + IK)
  bone_matrix_buffer_offset: u32, // offset into bone matrix buffer for skinned mesh
}

MeshAttachment :: struct {
  handle:              resources.MeshHandle,
  material:            resources.MaterialHandle,
  skinning:            Maybe(NodeSkinning),
  cast_shadow:         bool,
}

EmitterAttachment :: struct {
  handle: resources.EmitterHandle,
}

ForceFieldAttachment :: struct {
  handle: resources.ForceFieldHandle,
}

SpriteAttachment :: struct {
  sprite_handle: resources.SpriteHandle,
  mesh_handle:   resources.MeshHandle,
  material:      resources.MaterialHandle,
}

RigidBodyAttachment :: struct {
  body_handle:     physics.DynamicRigidBodyHandle,
}

NodeAttachment :: union {
  LightAttachment,
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
  clip_handle: resources.ClipHandle, // handle to animation clip (resolved at runtime)
  mode:        anim.PlayMode,
  status:      anim.Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

Node :: struct {
  parent:           resources.NodeHandle,
  children:         [dynamic]resources.NodeHandle,
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

TraverseEntry :: struct {
  handle:            resources.NodeHandle,
  parent_transform:  matrix[4, 4]f32,
  parent_is_dirty:   bool,
  parent_is_visible: bool,
}

World :: struct {
  root:                    resources.NodeHandle,
  nodes:                   resources.Pool(Node),
  traversal_stack:         [dynamic]TraverseEntry,
  actor_pools:             map[typeid]ActorPoolEntry,
  animatable_nodes:        [dynamic]resources.NodeHandle,
  pending_node_deletions:  [dynamic]resources.NodeHandle,
  pending_deletions_mutex: sync.Mutex,
}

init_node :: proc(self: ^Node, name: string = "") {
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
    resources.destroy_emitter(rm, attachment.handle)
    attachment.handle = {}
  case ForceFieldAttachment:
    resources.destroy_forcefield(rm, attachment.handle)
    attachment.handle = {}
  case SpriteAttachment:
    resources.destroy_sprite(rm, attachment.sprite_handle)
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
  }
}

detach :: proc(
  nodes: resources.Pool(Node),
  child_handle: resources.NodeHandle,
) {
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
  parent_handle, child_handle: resources.NodeHandle,
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
  if material, has_mat := cont.get(rm.materials, sprite_attachment.material);
     has_mat {
    switch material.type {
    case .TRANSPARENT:
      data.flags |= {.MATERIAL_TRANSPARENT}
    case .WIREFRAME:
      data.flags |= {.MATERIAL_WIREFRAME}
    case .PBR, .UNLIT: // No flags
    }
  }
}

spawn :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  handle: resources.NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_child(self, self.root, position, attachment, rm)
}

spawn_child :: proc(
  self: ^World,
  parent: resources.NodeHandle,
  position: [3]f32 = {0, 0, 0},
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  handle: resources.NodeHandle,
  ok: bool,
) #optional_ok {
  node: ^Node
  handle, node = cont.alloc(&self.nodes, resources.NodeHandle) or_return
  init_node(node)
  node.attachment = attachment
  assign_emitter_to_node(rm, handle, node)
  assign_forcefield_to_node(rm, handle, node)
  assign_light_to_node(rm, handle, node)
  update_node_tags(node)
  node.transform.position = position
  node.transform.is_dirty = true
  attach(self.nodes, parent, handle)
  if rm != nil {
      resources.node_upload_transform(rm, handle, &node.transform.world_matrix)
      data := resources.NodeData {
        material_id           = 0xFFFFFFFF,
        mesh_id               = 0xFFFFFFFF,
        attachment_data_index = 0xFFFFFFFF,
      }
      if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
        data.material_id = mesh_attachment.material.index
        data.mesh_id = mesh_attachment.handle.index
        // FIX: Must check both node.visible AND node.parent_visible (same as traverse logic)
        if node.visible && node.parent_visible do data.flags |= {.VISIBLE}
        if node.culling_enabled do data.flags |= {.CULLING_ENABLED}
        if mesh_attachment.cast_shadow do data.flags |= {.CASTS_SHADOW}
        if material, has_mat := cont.get(rm.materials, mesh_attachment.material);
           has_mat {
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
      resources.node_upload_data(rm, handle, &data)
  }
  return handle, true
}

init :: proc(world: ^World) {
  cont.init(&world.nodes, resources.MAX_NODES_IN_SCENE)
  root: ^Node
  world.root, root, _ = cont.alloc(&world.nodes, resources.NodeHandle)
  init_node(root, "root")
  root.parent = world.root
}


register_animatable_node :: proc(world: ^World, handle: resources.NodeHandle) {
  // TODO: if this list get more than 10000 items, we need to use a map
  if slice.contains(world.animatable_nodes[:], handle) do return
  append(&world.animatable_nodes, handle)
}

unregister_animatable_node :: proc(
  world: ^World,
  handle: resources.NodeHandle,
) {
  if i, found := slice.linear_search(world.animatable_nodes[:], handle);
     found {
    unordered_remove(&world.animatable_nodes, i)
  }
}

begin_frame :: proc(
  world: ^World,
  rm: ^resources.Manager,
  delta_time: f32 = 0.016,
  game_state: rawptr = nil,
  frame_index: u32 = 0,
) {
  traverse(world, rm, frame_index)
  world_tick_actors(world, rm, delta_time, game_state)
}

shutdown :: proc(
  world: ^World,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) {
  // Visibility system moved to Renderer
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
  delete(world.animatable_nodes)
  delete(world.pending_node_deletions)
}

despawn :: proc(world: ^World, handle: resources.NodeHandle) -> bool {
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
    log.warnf(
      "despawn: node %v '%s' already marked for deletion",
      handle,
      node.name,
    )
  }
  return true
}

cleanup_pending_deletions :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
) {
  zero_matrix: matrix[4, 4]f32
  zero_data: resources.NodeData
  for entry, i in world.nodes.entries do if entry.active {
    if !entry.item.pending_deletion do continue
    handle := resources.NodeHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    // Clear GPU buffers BEFORE freeing the node
    resources.node_upload_transform(rm, handle, &zero_matrix)
    resources.node_upload_data(rm, handle, &zero_data)
    unregister_animatable_node(world, handle)
    if node, ok := cont.free(&world.nodes, handle); ok {
      destroy_node(node, rm, gctx)
    }
  }
}

process_pending_deletions :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
) {
  sync.mutex_lock(&world.pending_deletions_mutex)
  defer sync.mutex_unlock(&world.pending_deletions_mutex)
  for handle in world.pending_node_deletions {
    despawn(world, handle)
  }
  had_deletions := len(world.pending_node_deletions) > 0
  clear(&world.pending_node_deletions)
  sync.mutex_unlock(&world.pending_deletions_mutex)
  cleanup_pending_deletions(world, rm, gctx)
  if had_deletions {
    resources.purge_unused_resources(rm, gctx)
  }
  sync.mutex_lock(&world.pending_deletions_mutex)
}

traverse :: proc(
  world: ^World,
  rm: ^resources.Manager = nil,
  frame_index: u32 = 0,
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
    is_dirty := update_local(&current_node.transform)
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
      bone_buffer := &rm.bone_buffer.buffers[frame_index]
      if bone_buffer.mapped == nil do break apply_bone_socket
      bone_matrices_ptr := gpu.get(
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
      // Bone socket provides an additional transform layer between parent and local
      // transform_update_world will multiply: (parent * bone_socket) * local_matrix
      update_world(
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
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
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
  node_handle: resources.NodeHandle,
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
  node_handle: resources.NodeHandle,
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
    gpu.write(
      &rm.lights_buffer.buffer,
      &light.data,
      int(attachment.handle.index),
    )
  }
}

create_point_light_attachment :: proc(
  node_handle: resources.NodeHandle,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: b32 = true,
) -> (
  attachment: LightAttachment,
  ok: bool,
) #optional_ok {
  handle: resources.LightHandle
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
  node_handle: resources.NodeHandle,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  cast_shadow: b32 = false,
) -> (
  attachment: LightAttachment,
  ok: bool,
) #optional_ok {
  handle: resources.LightHandle
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
  node_handle: resources.NodeHandle,
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
  handle: resources.LightHandle
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
      node_handle: resources.NodeHandle,
    ) -> (
      ActorHandle,
      bool,
    ) {
      return actor_alloc(cast(^ActorPool(T))pool_ptr, node_handle)
    },
    get_fn = proc(pool_ptr: rawptr, handle: ActorHandle) -> (rawptr, bool) {
      return actor_get(cast(^ActorPool(T))pool_ptr, handle)
    },
    free_fn = proc(pool_ptr: rawptr, handle: ActorHandle) -> bool {
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
  position: [3]f32 = {},
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  actor_handle: ActorHandle,
  ok: bool,
) #optional_ok {
  node_handle := spawn(world, position, attachment, rm) or_return
  pool := _ensure_actor_pool(world, T)
  return actor_alloc(pool, node_handle)
}

spawn_actor_child :: proc(
  world: ^World,
  $T: typeid,
  parent: resources.NodeHandle,
  position: [3]f32 = {},
  attachment: NodeAttachment = nil,
  rm: ^resources.Manager = nil,
) -> (
  actor_handle: ActorHandle,
  ok: bool,
) #optional_ok {
  node_handle := spawn_child(world, parent, position, attachment, rm) or_return
  pool := _ensure_actor_pool(world, T)
  return actor_alloc(pool, node_handle)
}

get_actor :: proc(
  world: ^World,
  $T: typeid,
  handle: ActorHandle,
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

free_actor :: proc(world: ^World, $T: typeid, handle: ActorHandle) -> bool {
  entry, pool_exists := world.actor_pools[typeid_of(T)]
  if !pool_exists do return false
  return entry.free_fn(entry.pool_ptr, handle)
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
