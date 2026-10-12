package mjolnir

import anim "animation"
import gltf_animation "animation/gltf"
import "core:log"
import "core:strings"
import "render"
import gltf_render "render/gltf"
import "vendor:cgltf"
import "world"

// A skinned node and the rig (index into GltfScene.rigs) that deforms it.
GltfSkinnedNode :: struct {
  node: world.NodeHandle,
  rig:  int,
}

// Result of load_gltf. World nodes and render resources belong to the world
// and renderer; the scene owns `roots`, `skinned` and the rigs (free with
// gltf_scene_destroy).
GltfScene :: struct {
  roots:   [dynamic]world.NodeHandle,
  rigs:    [dynamic]anim.Rig, // one per skin a mesh node uses, with every animation as a clip
  skinned: [dynamic]GltfSkinnedNode,
}

gltf_scene_destroy :: proc(self: ^GltfScene) {
  for &r in self.rigs do anim.rig_destroy(&r)
  delete(self.rigs)
  delete(self.roots)
  delete(self.skinned)
  self^ = {}
}

// Instantiate a glTF file: render looks (see gltf_render.load_meshes), one
// animation rig per skin (see gltf_animation.load_rig) and one world node per glTF
// node, spawned under `parent` (the world root by default).
load_gltf :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  path: string,
  parent: world.NodeHandle = {},
) -> (
  scene: GltfScene,
  ok: bool,
) #optional_ok {
  result := load_gltf_file(w, r, path, parent if parent != {} else w.root, &scene)
  if result != .success do log.errorf("Failed to load glTF %s: %v", path, result)
  return scene, result == .success
}

@(private = "file")
load_gltf_file :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  path: string,
  parent: world.NodeHandle,
  scene: ^GltfScene,
) -> cgltf.result {
  path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
  options: cgltf.options
  data := cgltf.parse_file(options, path_cstr) or_return
  defer cgltf.free(data)
  if len(data.buffers) > 0 do cgltf.load_buffers(options, data, path_cstr) or_return
  if len(data.nodes) == 0 do return .success
  looks, looks_ok := gltf_render.load_meshes(r, data, path, context.temp_allocator)
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
    rig := gltf_animation.load_rig(data, &skin) or_continue
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
  scene: ^GltfScene,
) {
  TraverseEntry :: struct {
    idx:    u32,
    parent: world.NodeHandle,
  }
  stack := make([dynamic]TraverseEntry, 0, context.temp_allocator)
  for &node, i in gltf_data.nodes do if node.parent == nil {
    append(&stack, TraverseEntry{idx = u32(i), parent = parent})
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    gltf_node := &gltf_data.nodes[entry.idx]
    node_handle := world.spawn_child(
      w,
      entry.parent,
      name = string(gltf_node.name),
    ) or_continue
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
        render.attach(r, node_handle.index, look)
        if gltf_node.skin != nil {
          if rig := skin_rigs[cgltf.skin_index(gltf_data, gltf_node.skin)]; rig >= 0 {
            append(&scene.skinned, GltfSkinnedNode{node = node_handle, rig = rig})
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
}
