package mjolnir

import "animation"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "core:slice"
import "geometry"
import "resource"

PointLightAttachment :: struct {
  color:       [4]f32,
  radius:      f32,
  cast_shadow: bool,
  cameras:     [6]resource.Handle, // One for each cube face
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
  camera:      resource.Handle,
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
}

ForceFieldAttachment :: struct {
  using force_field: ForceField,
}

NodeAttachment :: union {
  PointLightAttachment,
  DirectionalLightAttachment,
  SpotLightAttachment,
  MeshAttachment,
  ParticleSystemAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
}

Node :: struct {
  parent:          Handle,
  children:        [dynamic]Handle,
  transform:       geometry.Transform,
  name:            string,
  attachment:      NodeAttachment,
  culling_enabled: bool,
}

SceneTraversalCallback :: #type proc(node: ^Node, ctx: rawptr) -> bool

init_node :: proc(self: ^Node, name: string = "") {
  self.children = make([dynamic]Handle, 0)
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.culling_enabled = true
}

deinit_node :: proc(self: ^Node) {
  delete(self.children)
  data, has_mesh := &self.attachment.(MeshAttachment)
  if !has_mesh {
    return
  }
  skinning, has_skin := &data.skinning.?
  if !has_skin || skinning.bone_matrix_offset == 0xFFFFFFFF {
    return
  }
  resource.slab_free(&g_bone_matrix_slab, skinning.bone_matrix_offset)
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
  mesh := resource.get(g_meshes, data.handle)
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
  if node == nil {
    return
  }
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
  if node == nil {
    return
  }
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
  if node == nil {
    return
  }
  init_node(node)
  node.attachment = attachment
  attach(self.nodes, parent, handle)
  return
}

SceneTraverseEntry :: struct {
  handle:           Handle,
  parent_transform: matrix[4, 4]f32,
  parent_is_dirty:  bool,
}

Scene :: struct {
  main_camera:     resource.Handle,
  root:            Handle,
  nodes:           resource.Pool(Node),
  traversal_stack: [dynamic]SceneTraverseEntry,
}

scene_init :: proc(self: ^Scene) {
  // Create main camera
  main_camera_handle, main_camera_ptr := resource.alloc(&g_cameras)
  main_camera_ptr^ = geometry.make_camera_orbit(
    math.PI * 0.5, // fov
    16.0 / 9.0, // aspect_ratio
    0.1, // near
    20.0, // far
  )
  self.main_camera = main_camera_handle
  log.infof(
    "Initializing scene with main camera handle: %v",
    main_camera_handle,
  )
  // log.infof("Initializing nodes pool... ")
  resource.pool_init(&self.nodes)
  root: ^Node
  self.root, root = resource.alloc(&self.nodes)
  init_node(root, "root")
  root.parent = self.root
  self.traversal_stack = make([dynamic]SceneTraverseEntry, 0)
}

scene_deinit :: proc(self: ^Scene) {
  resource.pool_deinit(self.nodes, deinit_node)
  delete(self.traversal_stack)
}

switch_camera_mode_scene :: proc(self: ^Scene) {
  main_camera := resource.get(g_cameras, self.main_camera)
  if main_camera == nil {
    return
  }
  _, in_orbit_mode := main_camera.movement_data.(geometry.CameraOrbitMovement)
  if in_orbit_mode {
    geometry.camera_switch_to_free(main_camera)
  } else {
    geometry.camera_switch_to_orbit(main_camera, nil, nil)
  }
}

scene_traverse :: proc(
  self: ^Scene,
  cb_context: rawptr = nil,
  callback: SceneTraversalCallback = nil,
) -> bool {
  using geometry
  append(
    &self.traversal_stack,
    SceneTraverseEntry{self.root, linalg.MATRIX4F32_IDENTITY, false},
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
    is_dirty := transform_update_local(&current_node.transform)
    if entry.parent_is_dirty || is_dirty {
      transform_update_world(&current_node.transform, entry.parent_transform)
    }
    if callback != nil && !callback(current_node, cb_context) do continue
    for child_handle in current_node.children {
      append(
        &self.traversal_stack,
        SceneTraverseEntry {
          child_handle,
          current_node.transform.world_matrix,
          is_dirty || entry.parent_is_dirty,
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
  for &entry in self.nodes.entries do if entry.active {
    callback(&entry.item, cb_context)
  }
  return true
}
