package mjolnir

import anim "animation"
import gltf_animation "animation/gltf"
import "core:log"
import "core:strings"
import "geometry"
import "render"
import gltf_render "render/gltf"
import "vendor:cgltf"
import "world"

// A skinned node and the rig (index into GltfScene.rigs) that deforms it.
GltfSkinnedNode :: struct {
  node: world.NodeHandle,
  rig:  int,
}

// Result of load_gltf. World nodes and render resources belong to the engine;
// the scene owns `roots`, `skinned` and the rigs (free with gltf_scene_destroy).
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
// node.
load_gltf :: proc(engine: ^Engine, path: string) -> (scene: GltfScene, ok: bool) #optional_ok {
  result := load_gltf_file(engine, path, &scene)
  if result != .success do log.errorf("Failed to load glTF %s: %v", path, result)
  return scene, result == .success
}

@(private = "file")
load_gltf_file :: proc(engine: ^Engine, path: string, scene: ^GltfScene) -> cgltf.result {
  path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
  options: cgltf.options
  data := cgltf.parse_file(options, path_cstr) or_return
  defer cgltf.free(data)
  if len(data.buffers) > 0 do cgltf.load_buffers(options, data, path_cstr) or_return
  if len(data.nodes) == 0 do return .success
  looks, looks_ok := gltf_render.load_meshes(&engine.render, data, path, context.temp_allocator)
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
  construct_scene(engine, data, looks, skin_rigs, scene)
  return .success
}

@(private = "file")
construct_scene :: proc(
  engine: ^Engine,
  gltf_data: ^cgltf.data,
  looks: []Maybe(render.MeshAttachment),
  skin_rigs: []int,
  scene: ^GltfScene,
) {
  TraverseEntry :: struct {
    idx:    u32,
    parent: world.NodeHandle,
  }
  stack := make([dynamic]TraverseEntry, 0, context.temp_allocator)
  for &node, i in gltf_data.nodes do if node.parent == nil {
    append(&stack, TraverseEntry{idx = u32(i), parent = engine.world.root})
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    gltf_node := &gltf_data.nodes[entry.idx]
    node_handle := world.spawn_child(
      &engine.world,
      entry.parent,
      name = string(gltf_node.name),
    ) or_continue
    node := world.node(&engine.world, node_handle)
    if gltf_node.has_matrix {
      node.transform = geometry.decompose_matrix(
        transmute(matrix[4, 4]f32)gltf_node.matrix_,
      )
    } else {
      if gltf_node.has_translation {
        node.transform.position = gltf_node.translation
      }
      if gltf_node.has_rotation {
        node.transform.rotation = transmute(quaternion128)gltf_node.rotation
      }
      if gltf_node.has_scale {
        node.transform.scale = gltf_node.scale
      }
    }
    node.transform.is_dirty = true
    if gltf_node.mesh != nil {
      if look, has_look := looks[cgltf.mesh_index(gltf_data, gltf_node.mesh)].?; has_look {
        render.attach(&engine.render, node_handle.index, look)
        if gltf_node.skin != nil {
          if rig := skin_rigs[cgltf.skin_index(gltf_data, gltf_node.skin)]; rig >= 0 {
            append(&scene.skinned, GltfSkinnedNode{node = node_handle, rig = rig})
          }
        }
      }
    }
    if entry.parent == engine.world.root do append(&scene.roots, node_handle)
    for child_ptr in gltf_node.children {
      child_idx := cgltf.node_index(gltf_data, child_ptr)
      append(&stack, TraverseEntry{idx = u32(child_idx), parent = node_handle})
    }
  }
}
