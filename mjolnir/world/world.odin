package world

import "../animation"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "../geometry"
import "../gpu"
import "../render/particles"
import "../resources"
import vk "vendor:vulkan"

Handle :: resources.Handle

LightAttachment :: struct {
  handle: Handle,
}

NodeSkinning :: struct {
  animation:          Maybe(animation.Instance),
  bone_matrix_offset: u32,
}

MeshAttachment :: struct {
  handle:              Handle,
  material:            Handle,
  skinning:            Maybe(NodeSkinning),
  cast_shadow:         bool,
  navigation_obstacle: bool,
}

EmitterAttachment :: struct {
  handle: Handle,
}

ForceFieldAttachment :: struct {
  handle: Handle,
}

NodeAttachment :: union {
  LightAttachment,
  MeshAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
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

destroy_node :: proc(self: ^Node, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext = nil) {
  delete(self.children)
  if resources_manager == nil {
    return
  }

  // Handle light attachment cleanup
  #partial switch &attachment in &self.attachment {
  case LightAttachment:
    if attachment.handle.generation != 0 {
      if gpu_context != nil {
        resources.destroy_light(resources_manager, gpu_context, attachment.handle)
      } else {
        log.warn("Cannot properly destroy light without GPU context - this may leak shadow resources")
      }
      attachment.handle = {}
    }
  case EmitterAttachment:
    emitter := resources.get(resources_manager.emitters, attachment.handle)
    if emitter != nil {
      emitter.node_handle = {}
    }
    if resources.destroy_emitter_handle(resources_manager, attachment.handle) {
      attachment.handle = {}
    }
  case ForceFieldAttachment:
    forcefield := resources.get(resources_manager.forcefields, attachment.handle)
    if forcefield != nil {
      forcefield.node_handle = {}
    }
    if resources.destroy_forcefield_handle(resources_manager, attachment.handle) {
      attachment.handle = {}
    }
  case MeshAttachment:
    // TODO: we need to check if the mesh is still in use before freeing its resources
    skinning, has_skin := &attachment.skinning.?
    if has_skin && skinning.bone_matrix_offset != 0xFFFFFFFF {
      resources.slab_free(&resources_manager.bone_matrix_slab, skinning.bone_matrix_offset)
      skinning.bone_matrix_offset = 0xFFFFFFFF
    }
  }
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
  assign_forcefield_to_node(resources_manager, handle, node)
  assign_light_to_node(resources_manager, handle, node)
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
  attach(self.nodes, self.root, handle)
  // Mark world matrix and node data as dirty for new node
  if resources_manager != nil {
    world_matrix := node.transform.world_matrix
    gpu.write(&resources_manager.world_matrix_buffer, &world_matrix, int(handle.index))
    // Update node data buffer
    data := resources.NodeData {
      material_id        = 0xFFFFFFFF,
      mesh_id            = 0xFFFFFFFF,
      bone_matrix_offset = 0xFFFFFFFF,
      flags              = {},
    }
    if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
      data.material_id = mesh_attachment.material.index
      data.mesh_id = mesh_attachment.handle.index
      if node.visible {
        data.flags |= resources.NodeFlagSet{.VISIBLE}
      }
      if node.culling_enabled {
        data.flags |= {.CULLING_ENABLED}
      }
      if mesh_attachment.cast_shadow {
        data.flags |= resources.NodeFlagSet{.CASTS_SHADOW}
      }
      if mesh_attachment.navigation_obstacle {
        data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
      }
      if material_entry, has_material := resources.get(
        resources_manager.materials,
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
        data.bone_matrix_offset = skinning.bone_matrix_offset
      }
    }
    // Check for navigation obstacle attachment
    if _, is_obstacle := node.attachment.(NavMeshObstacleAttachment); is_obstacle {
      data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
    }
    gpu.write(&resources_manager.node_data_buffer, &data, int(handle.index))
  }
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
  assign_forcefield_to_node(resources_manager, handle, node)
  assign_light_to_node(resources_manager, handle, node)
  attach(self.nodes, self.root, handle)
  // Mark world matrix and node data as dirty for new node
  if resources_manager != nil {
    world_matrix := node.transform.world_matrix
    gpu.write(&resources_manager.world_matrix_buffer, &world_matrix, int(handle.index))
    // Update node data buffer
    data := resources.NodeData {
      material_id        = 0xFFFFFFFF,
      mesh_id            = 0xFFFFFFFF,
      bone_matrix_offset = 0xFFFFFFFF,
    }
    if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
      data.material_id = mesh_attachment.material.index
      data.mesh_id = mesh_attachment.handle.index
      if node.visible {
        data.flags |= resources.NodeFlagSet{.VISIBLE}
      }
      if node.culling_enabled {
        data.flags |= {.CULLING_ENABLED}
      }
      if mesh_attachment.cast_shadow {
        data.flags |= resources.NodeFlagSet{.CASTS_SHADOW}
      }
      if mesh_attachment.navigation_obstacle {
        data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
      }
      if material_entry, has_material := resources.get(
        resources_manager.materials,
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
        data.bone_matrix_offset = skinning.bone_matrix_offset
      }
    }
    // Check for navigation obstacle attachment
    if _, is_obstacle := node.attachment.(NavMeshObstacleAttachment); is_obstacle {
      data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
    }
    gpu.write(&resources_manager.node_data_buffer, &data, int(handle.index))
  }
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
  assign_forcefield_to_node(resources_manager, handle, node)
  assign_light_to_node(resources_manager, handle, node)
  attach(self.nodes, parent, handle)
  // Mark world matrix and node data as dirty for new node
  if resources_manager != nil {
    world_matrix := node.transform.world_matrix
    gpu.write(&resources_manager.world_matrix_buffer, &world_matrix, int(handle.index))
    // Update node data buffer
    data := resources.NodeData {
      material_id        = 0xFFFFFFFF,
      mesh_id            = 0xFFFFFFFF,
      bone_matrix_offset = 0xFFFFFFFF,
    }
    if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
      data.material_id = mesh_attachment.material.index
      data.mesh_id = mesh_attachment.handle.index
      if node.visible {
        data.flags |= resources.NodeFlagSet{.VISIBLE}
      }
      if node.culling_enabled {
        data.flags |= {.CULLING_ENABLED}
      }
      if mesh_attachment.cast_shadow {
        data.flags |= resources.NodeFlagSet{.CASTS_SHADOW}
      }
      if mesh_attachment.navigation_obstacle {
        data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
      }
      if material_entry, has_material := resources.get(
        resources_manager.materials,
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
        data.bone_matrix_offset = skinning.bone_matrix_offset
      }
    }
    // Check for navigation obstacle attachment
    if _, is_obstacle := node.attachment.(NavMeshObstacleAttachment); is_obstacle {
      data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
    }
    gpu.write(&resources_manager.node_data_buffer, &data, int(handle.index))
  }
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

destroy :: proc(world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext = nil) {
  for &entry in world.nodes.entries {
    if entry.active {
      destroy_node(&entry.item, resources_manager, gpu_context)
    }
  }
  resources.pool_destroy(world.nodes, proc(node: ^Node) {})
  delete(world.traversal_stack)
}

init_gpu :: proc(
  world: ^World,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  return visibility_system_init(&world.visibility, gpu_context, resources_manager)
}

begin_frame :: proc(world: ^World, resources_manager: ^resources.Manager) {
  traverse(world, resources_manager)
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
    command_stride = result.command_stride,
  }
}

shutdown :: proc(world: ^World, gpu_context: ^gpu.GPUContext, resources_manager: ^resources.Manager) {
  visibility_system_shutdown(&world.visibility, gpu_context)
  destroy(world, resources_manager, gpu_context)
}

get_visible_count :: proc(
  world: ^World,
  frame_index: u32,
  category: VisibilityCategory,
) -> u32 {
  return visibility_system_get_visible_count(&world.visibility, frame_index, category)
}

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
  assign_forcefield_to_node(resources_manager, handle, node)
  assign_light_to_node(resources_manager, handle, node)
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
  attach(world.nodes, world.root, handle)
  // Mark world matrix and node data as dirty for new node
  if resources_manager != nil {
    world_matrix := node.transform.world_matrix
    gpu.write(&resources_manager.world_matrix_buffer, &world_matrix, int(handle.index))
    // Update node data buffer
    data := resources.NodeData {
      material_id        = 0xFFFFFFFF,
      mesh_id            = 0xFFFFFFFF,
      bone_matrix_offset = 0xFFFFFFFF,
    }
    if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
      data.material_id = mesh_attachment.material.index
      data.mesh_id = mesh_attachment.handle.index
      if node.visible {
        data.flags |= resources.NodeFlagSet{.VISIBLE}
      }
      if node.culling_enabled {
        data.flags |= {.CULLING_ENABLED}
      }
      if mesh_attachment.cast_shadow {
        data.flags |= resources.NodeFlagSet{.CASTS_SHADOW}
      }
      if mesh_attachment.navigation_obstacle {
        data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
      }
      if material_entry, has_material := resources.get(
        resources_manager.materials,
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
        data.bone_matrix_offset = skinning.bone_matrix_offset
      }
    }
    // Check for navigation obstacle attachment
    if _, is_obstacle := node.attachment.(NavMeshObstacleAttachment); is_obstacle {
      data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
    }
    gpu.write(&resources_manager.node_data_buffer, &data, int(handle.index))
  }
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
  assign_forcefield_to_node(resources_manager, handle, node)
  assign_light_to_node(resources_manager, handle, node)
  geometry.transform_translate(&node.transform, position.x, position.y, position.z)
  attach(world.nodes, parent, handle)
  if resources_manager != nil {
    world_matrix := node.transform.world_matrix
    gpu.write(&resources_manager.world_matrix_buffer, &world_matrix, int(handle.index))
    // Update node data buffer
    data := resources.NodeData {
      material_id        = 0xFFFFFFFF,
      mesh_id            = 0xFFFFFFFF,
      bone_matrix_offset = 0xFFFFFFFF,
    }
    if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
      data.material_id = mesh_attachment.material.index
      data.mesh_id = mesh_attachment.handle.index
      if node.visible {
        data.flags |= resources.NodeFlagSet{.VISIBLE}
      }
      if node.culling_enabled {
        data.flags |= {.CULLING_ENABLED}
      }
      if mesh_attachment.cast_shadow {
        data.flags |= resources.NodeFlagSet{.CASTS_SHADOW}
      }
      if mesh_attachment.navigation_obstacle {
        data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
      }
      if material_entry, has_material := resources.get(
        resources_manager.materials,
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
        data.bone_matrix_offset = skinning.bone_matrix_offset
      }
    }
    // Check for navigation obstacle attachment
    if _, is_obstacle := node.attachment.(NavMeshObstacleAttachment); is_obstacle {
      data.flags |= resources.NodeFlagSet{.NAVIGATION_OBSTACLE}
    }
    gpu.write(&resources_manager.node_data_buffer, &data, int(handle.index))
  }
  return
}

destroy_node_handle :: proc(world: ^World, handle: Handle) -> bool {
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

// Actually destroy nodes that are marked for deletion
cleanup_pending_deletions :: proc(world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext = nil) {
  to_destroy := make([dynamic]Handle, 0)
  defer delete(to_destroy)
  for i in 0 ..< len(world.nodes.entries) {
    entry := &world.nodes.entries[i]
    if entry.active && entry.item.pending_deletion {
      append(&to_destroy, Handle{index = u32(i), generation = entry.generation})
    }
  }
  for handle in to_destroy {
    if node, ok := resources.free(&world.nodes, handle); ok {
      destroy_node(node, resources_manager, gpu_context)
    }
  }
}

get_node :: proc(world: ^World, handle: Handle) -> ^Node {
  return resources.get(world.nodes, handle)
}

// Emitter synchronization for particle system

@(private)
update_visibility_system :: proc(world: ^World) {
  count := slice.count_proc(world.nodes.entries[:], proc(entry: resources.Entry(Node)) -> bool {
      return entry.active
  })
  visibility_system_set_node_count(&world.visibility, u32(count))
}

traverse :: proc(world: ^World, resources_manager: ^resources.Manager = nil, cb_context: rawptr = nil, callback: TraversalCallback = nil) -> bool {
  using geometry
  append(
    &world.traversal_stack,
    TraverseEntry{world.root, linalg.MATRIX4F32_IDENTITY, false, true},
  )
  for len(world.traversal_stack) > 0 {
    entry := pop(&world.traversal_stack)
    current_node, found := resources.get(world.nodes, entry.handle)
    if !found {
      // log.errorf(
      //   "traverse_scene: Node with handle %v not found\n",
      //   entry.handle,
      // )
      continue
    }
    if current_node.pending_deletion do continue
    // Update parent_visible from parent chain only
    visibility_changed := current_node.parent_visible != entry.parent_is_visible
    current_node.parent_visible = entry.parent_is_visible
    is_dirty := transform_update_local(&current_node.transform)
    if entry.parent_is_dirty || is_dirty {
      transform_update_world(&current_node.transform, entry.parent_transform)
      if resources_manager != nil {
        world_matrix := current_node.transform.world_matrix
        gpu.write(&resources_manager.world_matrix_buffer, &world_matrix, int(entry.handle.index))
      }
    }
    // Update node data when visibility changes
    if (visibility_changed || is_dirty || entry.parent_is_dirty) && resources_manager != nil {
      data := resources.NodeData {
        material_id        = 0xFFFFFFFF,
        mesh_id            = 0xFFFFFFFF,
        bone_matrix_offset = 0xFFFFFFFF,
      }
      if mesh_attachment, has_mesh := current_node.attachment.(MeshAttachment); has_mesh {
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
        if material_entry, has_material := resources.get(
          resources_manager.materials,
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
          data.bone_matrix_offset = skinning.bone_matrix_offset
        }
      }
      gpu.write(&resources_manager.node_data_buffer, &data, int(entry.handle.index))
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
          current_node.transform.world_matrix,
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
    resources.emitter_write_to_gpu(resources_manager, attachment.handle, emitter)
  }
}

@(private)
assign_forcefield_to_node :: proc(
  resources_manager: ^resources.Manager,
  node_handle: Handle,
  node: ^Node,
) {
  if resources_manager == nil {
    return
  }
  attachment, is_forcefield := &node.attachment.(ForceFieldAttachment)
  if !is_forcefield {
    return
  }
  forcefield, ok := resources.get(resources_manager.forcefields, attachment.handle)
  if ok {
    forcefield.node_handle = node_handle
    resources.forcefield_write_to_gpu(resources_manager, attachment.handle, forcefield)
  }
}

@(private)
assign_light_to_node :: proc(
  resources_manager: ^resources.Manager,
  node_handle: Handle,
  node: ^Node,
) {
  if resources_manager == nil {
    return
  }
  attachment, is_light := &node.attachment.(LightAttachment)
  if !is_light {
    return
  }
  light, ok := resources.get_light(resources_manager, attachment.handle)
  if ok {
    light.node_handle = node_handle
    light.node_index = node_handle.index
    gpu.write(&resources_manager .lights_buffer, &light.data, int(attachment.handle.index))
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

node_handle_translate_by :: proc(world: ^World, handle: Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_translate_by(&node.transform, x, y, z)
  }
}

node_handle_translate :: proc(world: ^World, handle: Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_translate(&node.transform, x, y, z)
  }
}

node_handle_rotate_by :: proc {
  node_handle_rotate_by_quaternion,
  node_handle_rotate_by_angle,
}

node_handle_rotate_by_quaternion :: proc(world: ^World, handle: Handle, q: quaternion128) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_rotate_by_quaternion(&node.transform, q)
  }
}

node_handle_rotate_by_angle :: proc(
  world: ^World,
  handle: Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_rotate_by_angle(&node.transform, angle, axis)
  }
}

node_handle_rotate :: proc {
  node_handle_rotate_quaternion,
  node_handle_rotate_angle,
}

node_handle_rotate_quaternion :: proc(world: ^World, handle: Handle, q: quaternion128) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_rotate_quaternion(&node.transform, q)
  }
}

node_handle_rotate_angle :: proc(
  world: ^World,
  handle: Handle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_rotate_angle(&node.transform, angle, axis)
  }
}

node_handle_scale_xyz_by :: proc(world: ^World, handle: Handle, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_scale_xyz_by(&node.transform, x, y, z)
  }
}

node_handle_scale_by :: proc(world: ^World, handle: Handle, s: f32) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_scale_by(&node.transform, s)
  }
}

node_handle_scale_xyz :: proc(world: ^World, handle: Handle, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_scale_xyz(&node.transform, x, y, z)
  }
}

node_handle_scale :: proc(world: ^World, handle: Handle, s: f32) {
  if node, ok := resources.get(world.nodes, handle); ok {
    geometry.transform_scale(&node.transform, s)
  }
}

// Create point light attachment and associated Light resource
create_point_light_attachment :: proc(
  node_handle: Handle,
  resources_manager: ^resources.Manager,
  gpu_context: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: b32 = true,
) -> LightAttachment {
  light_handle := resources.create_light(
    resources_manager,
    gpu_context,
    .POINT,
    node_handle,
    color,
    radius,
    cast_shadow = cast_shadow,
  )

  return LightAttachment{handle = light_handle}
}

// Create directional light attachment and associated Light resource
create_directional_light_attachment :: proc(
  node_handle: Handle,
  resources_manager: ^resources.Manager,
  gpu_context: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  cast_shadow: b32 = false,
) -> LightAttachment {
  light_handle := resources.create_light(
    resources_manager,
    gpu_context,
    .DIRECTIONAL,
    node_handle,
    color,
    cast_shadow = cast_shadow,
  )
  return LightAttachment{handle = light_handle}
}

// Create spot light attachment and associated Light resource
create_spot_light_attachment :: proc(
  node_handle: Handle,
  resources_manager: ^resources.Manager,
  gpu_context: ^gpu.GPUContext,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> LightAttachment {
  angle_inner := angle * 0.8
  angle_outer := angle
  light_handle := resources.create_light(
    resources_manager,
    gpu_context,
    .SPOT,
    node_handle,
    color,
    radius,
    angle_inner,
    angle_outer,
    cast_shadow,
  )
  return LightAttachment{handle = light_handle}
}
