package gltf

import "../animation"
import "../render"
import "../world"
import "core:log"
import "core:math/linalg"
import "core:strings"
import "vendor:cgltf"

// RigHandle identifies a rig of a Scene: its index in Scene.rigs.
RigHandle :: distinct u32

// Joint is the world node of a rig's bone: what hangs under it (a sword in a hand) follows the
// bone once pose_joints runs.
Joint :: struct {
  node: world.NodeHandle,
  rig:  RigHandle,
  bone: u32,
}

// SkinnedNode is a skinned node and the rig that deforms it. Several nodes may share a rig.
SkinnedNode :: struct {
  node: world.NodeHandle,
  rig:  RigHandle,
}

// Scene is what scene_create made: the world nodes under `roots`, the render meshes, materials
// and textures they draw, and the rigs. scene_destroy frees all of it.
Scene :: struct {
  roots:     [dynamic]world.NodeHandle,
  rigs:      [dynamic]animation.Rig, // one per skin a mesh node uses, with every animation as a clip
  skinned:   [dynamic]SkinnedNode,
  joints:    [dynamic]Joint,
  names:     [dynamic]string, // the node names, which world borrows
  meshes:    [dynamic]render.MeshHandle,
  materials: [dynamic]render.MaterialHandle,
  textures:  [dynamic]render.TextureHandle,
}

// scene_destroy destroys the scene's nodes (roots and their descendants) and render
// resources, and frees its rigs.
scene_destroy :: proc(self: ^Scene, w: ^world.World, r: ^render.Renderer) {
  for h in self.roots do world.destroy(w, h)
  for h in self.meshes do render.destroy(r, h)
  for h in self.materials do render.destroy(r, h)
  for h in self.textures do render.destroy(r, h)
  for &rig in self.rigs do animation.rig_destroy(&rig)
  for name in self.names do delete(name)
  delete(self.names)
  delete(self.joints)
  delete(self.rigs)
  delete(self.roots)
  delete(self.skinned)
  delete(self.meshes)
  delete(self.materials)
  delete(self.textures)
  self^ = {}
}

// scene_create instantiates a glTF held in memory, a .glb or a glTF whose buffers and images are
// all embedded (the engine reads no files: #load it or platform.read_file it): render looks (see
// load_meshes), one rig per skin (see rig_create) and one world node per glTF node, spawned
// under `parent` (the world root by default) with its look attached. A skinned node moves once
// the app animates its rig (animation.animator_update) and stages the palette each tick
// (render.stage_bones).
scene_create :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  data: []u8,
  parent: world.NodeHandle = {},
) -> (
  scene: Scene,
  ok: bool,
) #optional_ok {
  result := load_data(w, r, data, parent if parent != {} else w.root, &scene)
  if result != .success {
    log.errorf("Failed to load glTF: %v", result)
    scene_destroy(&scene, w, r)
    return {}, false
  }
  return scene, true
}

@(private = "file")
load_data :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  bytes: []u8,
  parent: world.NodeHandle,
  scene: ^Scene,
) -> cgltf.result {
  options: cgltf.options
  data := cgltf.parse(options, raw_data(bytes), uint(len(bytes))) or_return
  defer cgltf.free(data)
  // no gltf path: a .glb's BIN chunk and data: URIs load, a buffer in another file fails
  if len(data.buffers) > 0 do cgltf.load_buffers(options, data, nil) or_return
  if len(data.nodes) == 0 do return .success
  looks, looks_ok := load_meshes(r, data, scene, context.temp_allocator)
  if !looks_ok do return .invalid_gltf
  // rig index per skin; -1 when no mesh node uses the skin or it failed to load
  skin_rigs := make([]int, len(data.skins), context.temp_allocator)
  skin_used := make([]bool, len(data.skins), context.temp_allocator)
  for &node in data.nodes do if node.mesh != nil && node.skin != nil {
    skin_used[cgltf.skin_index(data, node.skin)] = true
  }
  for &skin, i in data.skins {
    skin_rigs[i] = -1
    if !skin_used[i] do continue
    rig := rig_create(data, &skin) or_continue
    skin_rigs[i] = len(scene.rigs)
    append(&scene.rigs, rig)
  }
  construct_scene(w, r, data, looks, skin_rigs, parent, scene)
  return .success
}

@(private = "file")
construct_scene :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  gltf_data: ^cgltf.data,
  looks: []Maybe(render.MeshAttachment),
  skin_rigs: []int,
  parent: world.NodeHandle,
  scene: ^Scene,
) {
  TraverseEntry :: struct {
    idx:    u32,
    parent: world.NodeHandle,
  }
  stack := make([dynamic]TraverseEntry, 0, context.temp_allocator)
  nodes := make([]world.NodeHandle, len(gltf_data.nodes), context.temp_allocator)
  for &node, i in gltf_data.nodes do if node.parent == nil {
    append(&stack, TraverseEntry{idx = u32(i), parent = parent})
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    gltf_node := &gltf_data.nodes[entry.idx]
    name := strings.clone(string(gltf_node.name))
    append(&scene.names, name)
    node_handle := world.spawn(w, name = name, parent = entry.parent) or_continue
    nodes[entry.idx] = node_handle
    if gltf_node.has_matrix {
      world.set_local_matrix(
        w,
        node_handle,
        transmute(matrix[4, 4]f32)gltf_node.matrix_,
      )
    } else {
      // cgltf fills absent components with identity values
      world.set_local(
        w,
        node_handle,
        gltf_node.translation,
        transmute(quaternion128)gltf_node.rotation,
        gltf_node.scale,
      )
    }
    if gltf_node.mesh != nil {
      if look, has_look := looks[cgltf.mesh_index(gltf_data, gltf_node.mesh)].?; has_look {
        render.attach(r, render.SlotHandle(node_handle.index), look)
        if gltf_node.skin != nil {
          if rig := skin_rigs[cgltf.skin_index(gltf_data, gltf_node.skin)]; rig >= 0 {
            append(&scene.skinned, SkinnedNode{node = node_handle, rig = RigHandle(rig)})
          }
        }
      }
    }
    if entry.parent == parent do append(&scene.roots, node_handle)
    for child_ptr in gltf_node.children {
      child_idx := cgltf.node_index(gltf_data, child_ptr)
      append(&stack, TraverseEntry{idx = u32(child_idx), parent = node_handle})
    }
  }
  for &skin, i in gltf_data.skins do if rig := skin_rigs[i]; rig >= 0 {
    for joint_node, bone in skin.joints {
      node := nodes[cgltf.node_index(gltf_data, joint_node)]
      if node != {} do append(&scene.joints, Joint{node = node, rig = RigHandle(rig), bone = u32(bone)})
    }
  }
}

// pose_joints moves the joint nodes of `rig` to the animator's pose; call it after
// animation.animator_update so nodes under them follow the animation.
pose_joints :: proc(self: ^Scene, w: ^world.World, rig: RigHandle, animator: ^animation.Animator) {
  parents := self.rigs[rig].skeleton.parents
  for j in self.joints do if j.rig == rig {
    local := animation.bone_matrix(animator, j.bone)
    if parent := parents[j.bone]; parent >= 0 {
      local = linalg.inverse(animation.bone_matrix(animator, u32(parent))) * local
    }
    world.set_local_matrix(w, j.node, local)
  }
}

// destroy frees a Scene, as scene_destroy does.
destroy :: proc {
  scene_destroy,
}
