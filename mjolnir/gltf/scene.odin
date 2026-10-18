package gltf

import "../animation"
import "../geometry"
import "../render"
import "../world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "vendor:cgltf"

// RigHandle identifies a rig of a Model: its index in Model.rigs.
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

// Model is a glTF loaded once (model_create): its render meshes, materials and textures, its
// rigs, and the node tree every instance_create spawns. It must outlive its instances.
Model :: struct {
  rigs:      [dynamic]animation.Rig, // one per skin a mesh node uses, with every animation as a clip
  meshes:    [dynamic]render.MeshHandle,
  materials: [dynamic]render.MaterialHandle,
  textures:  [dynamic]render.TextureHandle,
  lights:    [dynamic]render.LightHandle, // KHR_lights_punctual, in the file's units (lux, candela)
  using _:   Model_Nodes,
}

@(private)
Model_Nodes :: struct {
  // parents before children
  nodes:  [dynamic]ModelNode,
  // the template node of each rig's bones
  joints: [dynamic]ModelJoint,
}

// One glTF node as instance_create spawns it.
@(private)
ModelNode :: struct {
  name:      string, // world borrows it
  parent:    int, // -1 for a root
  transform: world.Transform,
  look:      render.MeshAttachment, // mesh 0 draws nothing
  rig:       int, // the rig deforming its mesh, -1 for none
  light:     Maybe(render.LightHandle),
}

@(private)
ModelJoint :: struct {
  node: int,
  rig:  RigHandle,
  bone: u32,
}

// Instance is one copy of a Model in the world (instance_create): the nodes under `roots`, the
// skinned ones and the joints of each rig.
Instance :: struct {
  roots:   [dynamic]world.NodeHandle,
  skinned: [dynamic]SkinnedNode,
  joints:  [dynamic]Joint,
}

// model_create loads a glTF held in memory, a .glb or a glTF whose buffers and images are all
// embedded (the engine reads no files: #load it or platform.read_file it): a render mesh
// and material per primitive of each glTF mesh a node uses, with their textures (skinned where a
// skinned node uses it), a light per light node (model.lights, in the file's units), and one rig per skin with every glTF animation as its clips. Spawn it with instance_create.
model_create :: proc(r: ^render.Renderer, data: []u8) -> (model: Model, ok: bool) #optional_ok {
  result := load_data(r, data, &model)
  if result != .success {
    log.errorf("Failed to load glTF: %v", result)
    model_destroy(&model, r)
    return {}, false
  }
  return model, true
}

// model_destroy frees the model's render resources and rigs. Destroy its instances first.
model_destroy :: proc(self: ^Model, r: ^render.Renderer) {
  for h in self.meshes do render.destroy(r, h)
  for h in self.materials do render.destroy(r, h)
  for h in self.textures do render.destroy(r, h)
  for h in self.lights do render.light_destroy(r, h)
  for &rig in self.rigs do animation.rig_destroy(&rig)
  for n in self.nodes do delete(n.name)
  delete(self.rigs)
  delete(self.meshes)
  delete(self.materials)
  delete(self.textures)
  delete(self.lights)
  delete(self.nodes)
  delete(self.joints)
  self^ = {}
}

// instance_create spawns one world node per glTF node of the model under `parent` (the world
// root by default), each drawing its mesh. A skinned node moves once the app animates its rig
// (animation.animator_update) and stages the palette each tick (render.stage_bones).
instance_create :: proc(
  model: ^Model,
  w: ^world.World,
  r: ^render.Renderer,
  parent: world.NodeHandle = {},
) -> (
  instance: Instance,
  ok: bool,
) #optional_ok {
  root := parent if parent != {} else w.root
  nodes := make([]world.NodeHandle, len(model.nodes), context.temp_allocator)
  for n, i in model.nodes {
    handle := world.spawn(w, name = n.name, parent = root if n.parent < 0 else nodes[n.parent]) or_continue
    nodes[i] = handle
    world.set_local(w, handle, n.transform.position, n.transform.rotation, n.transform.scale)
    if n.parent < 0 do append(&instance.roots, handle)
    if light, has_light := n.light.?; has_light {
      // a light and a mesh share a slot only through a child node
      slot := handle
      if n.look.mesh != 0 do slot = world.spawn(w, parent = handle) or_continue
      render.attach(r, render.SlotHandle(slot.index), light)
    }
    if n.look.mesh == 0 do continue
    render.attach(r, render.SlotHandle(handle.index), n.look)
    if n.rig >= 0 do append(&instance.skinned, SkinnedNode{node = handle, rig = RigHandle(n.rig)})
  }
  for j in model.joints do if nodes[j.node] != {} {
    append(&instance.joints, Joint{node = nodes[j.node], rig = j.rig, bone = j.bone})
  }
  return instance, len(instance.roots) > 0
}

// instance_destroy destroys the instance's nodes (roots and their descendants).
instance_destroy :: proc(self: ^Instance, w: ^world.World) {
  for h in self.roots do world.destroy(w, h)
  delete(self.roots)
  delete(self.skinned)
  delete(self.joints)
  self^ = {}
}

@(private = "file")
load_data :: proc(r: ^render.Renderer, bytes: []u8, model: ^Model) -> cgltf.result {
  options: cgltf.options
  data := cgltf.parse(options, raw_data(bytes), uint(len(bytes))) or_return
  defer cgltf.free(data)
  // no gltf path: a .glb's BIN chunk and data: URIs load, a buffer in another file fails
  if len(data.buffers) > 0 do cgltf.load_buffers(options, data, nil) or_return
  if len(data.nodes) == 0 do return .success
  looks, looks_ok := load_meshes(r, data, model, context.temp_allocator)
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
    skin_rigs[i] = len(model.rigs)
    append(&model.rigs, rig)
  }
  load_nodes(r, data, looks, skin_rigs, model)
  return .success
}

// The node tree, parents first: model.nodes[template[i]] is glTF node i.
@(private = "file")
load_nodes :: proc(r: ^render.Renderer, data: ^cgltf.data, looks: [][dynamic]render.MeshAttachment, skin_rigs: []int, model: ^Model) {
  Entry :: struct {
    idx:    int,
    parent: int,
  }
  stack := make([dynamic]Entry, 0, context.temp_allocator)
  template := make([]int, len(data.nodes), context.temp_allocator)
  for &node, i in data.nodes {
    template[i] = -1
    if node.parent == nil do append(&stack, Entry{idx = i, parent = -1})
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    gltf_node := &data.nodes[entry.idx]
    n := ModelNode{name = strings.clone(string(gltf_node.name)), parent = entry.parent, rig = -1}
    if gltf_node.has_matrix {
      n.transform.position, n.transform.rotation, n.transform.scale = geometry.decompose_matrix(transmute(matrix[4, 4]f32)gltf_node.matrix_)
    } else {
      // cgltf fills absent components with identity values
      n.transform = {gltf_node.translation, transmute(quaternion128)gltf_node.rotation, gltf_node.scale}
    }
    if gltf_node.light != nil do n.light = load_light(r, gltf_node.light, model)
    prims: []render.MeshAttachment
    if gltf_node.mesh != nil {
      prims = looks[cgltf.mesh_index(data, gltf_node.mesh)][:]
      if len(prims) > 0 {
        n.look = prims[0]
        if gltf_node.skin != nil do n.rig = skin_rigs[cgltf.skin_index(data, gltf_node.skin)]
      }
    }
    template[entry.idx] = len(model.nodes)
    append(&model.nodes, n)
    // a mesh's further primitives, each with its own material, hang under the node
    for look in prims[min(1, len(prims)):] {
      append(
        &model.nodes,
        ModelNode {
          name = strings.clone(string(gltf_node.name)),
          parent = template[entry.idx],
          transform = {rotation = quaternion128(1), scale = 1},
          look = look,
          rig = n.rig,
        },
      )
    }
    for child in gltf_node.children {
      append(&stack, Entry{idx = int(cgltf.node_index(data, child)), parent = template[entry.idx]})
    }
  }
  for &skin, i in data.skins do if rig := skin_rigs[i]; rig >= 0 {
    for joint_node, bone in skin.joints {
      if node := template[cgltf.node_index(data, joint_node)]; node >= 0 {
        append(&model.joints, ModelJoint{node = node, rig = RigHandle(rig), bone = u32(bone)})
      }
    }
  }
}

// A light of the file, in its units (lux, candela): the app scales it to the engine's with
// render.light. A light with no range gets a default radius of 10. A directional light is
// skipped: the scene's sun is render.Renderer.sun.
@(private = "file")
load_light :: proc(r: ^render.Renderer, light: ^cgltf.light, model: ^Model) -> Maybe(render.LightHandle) {
  reach := light.range if light.range > 0 else 10
  l: render.Light
  switch light.type {
  case .directional:
    return nil
  case .point:
    l = render.make_point_light(light.color, light.intensity, reach)
  case .spot:
    l = render.make_spot_light(light.color, light.intensity, reach, light.spot_outer_cone_angle)
    l.angle_inner = light.spot_inner_cone_angle
  case .invalid:
    return nil
  }
  handle, ok := render.light_create(r, l)
  if !ok do return nil
  append(&model.lights, handle)
  return handle
}

// pose_joints moves the instance's joint nodes of `rig` to the animator's pose; call it after
// animation.animator_update so nodes under them follow the animation.
pose_joints :: proc(self: ^Instance, w: ^world.World, model: ^Model, rig: RigHandle, animator: ^animation.Animator) {
  parents := model.rigs[rig].skeleton.parents
  for j in self.joints do if j.rig == rig {
    local := animation.bone_matrix(animator, j.bone)
    if parent := parents[j.bone]; parent >= 0 {
      local = linalg.inverse(animation.bone_matrix(animator, u32(parent))) * local
    }
    world.set_local_matrix(w, j.node, local)
  }
}

// destroy frees a Model or an Instance, as model_destroy and instance_destroy do.
destroy :: proc {
  model_destroy,
  instance_destroy,
}
