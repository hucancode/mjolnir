package gltf

import "../geometry"
import "../animation"
import "../asset"
import "../render"
import "../world"
import "core:log"
import "core:math/linalg"
import "core:strings"

// RigHandle identifies a rig of a Model: its index in Model.rigs.
RigHandle :: distinct u32

// Joint is the world node of a rig's bone: what hangs under it (a sword in a hand) follows the
// bone as animate poses it.
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

// Model is a glTF loaded once (model_create), by the file's indices: meshes[i] draws mesh i,
// one attachment per primitive (none for a mesh no node uses); materials[i] is material i;
// lights[i] is light i, 0 for a directional one; textures are the images the materials sample;
// rigs are one per skin a mesh node uses, with every animation as a clip. It holds the node
// tree every instance_create spawns, and must outlive its instances.
Model :: struct {
  rigs:      [dynamic]animation.Rig,
  meshes:    [][]render.MeshAttachment,
  materials: []render.MaterialHandle,
  lights:    []render.LightHandle,
  textures:  [dynamic]render.TextureHandle,
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
  transform: geometry.Transform,
  look:      render.MeshAttachment, // mesh 0 draws nothing
  rig:       int, // the rig deforming its mesh, -1 for none
  light:     render.LightHandle,
}

@(private)
ModelJoint :: struct {
  node: int,
  rig:  RigHandle,
  bone: u32,
}

// Instance is one copy of a Model in the world (instance_create): the nodes under `roots`, the
// skinned ones, the joints of each rig, and per rig of the model (indexed by RigHandle) an
// animator posing every skinned node and joint of that rig and the palette they deform by;
// animate runs them.
Instance :: struct {
  roots:     [dynamic]world.NodeHandle,
  skinned:   [dynamic]SkinnedNode,
  joints:    [dynamic]Joint,
  animators: []animation.Animator,
  bones:     []render.BonesHandle,
}

// model_create loads a glTF held in memory, a .glb or a glTF whose buffers and images are all
// embedded (asset.load_gltf), into render and animation (one rig per skin a mesh node uses).
// Spawn it with instance_create.
model_create :: proc(r: ^render.Renderer, data: []u8) -> (model: Model, ok: bool) #optional_ok {
  file := asset.load_gltf(data) or_return
  defer asset.destroy(&file)
  if !upload(&model, r, &file) {
    model_destroy(&model, r)
    return {}, false
  }
  // rig index per skin; -1 when no mesh node uses the skin or it failed to load
  skin_rigs := make([]int, len(file.skins), context.temp_allocator)
  for &rig in skin_rigs do rig = -2
  for n in file.nodes do if n.mesh >= 0 && n.skin >= 0 do skin_rigs[n.skin] = -1
  for &rig, skin in skin_rigs do if rig == -1 {
    if built, built_ok := rig_from(&file, skin); built_ok {
      rig = len(model.rigs)
      append(&model.rigs, built)
    } else {
      log.warnf("glTF skin %d: invalid joint hierarchy", skin)
    }
  }
  // the tree, parents first like the file's: model.nodes[template[i]] is file node i
  template := make([]int, len(file.nodes), context.temp_allocator)
  for n, i in file.nodes {
    node := ModelNode{name = strings.clone(n.name), parent = template[n.parent] if n.parent >= 0 else -1, transform = n.transform, rig = -1}
    if n.light >= 0 do node.light = model.lights[n.light]
    prims: []render.MeshAttachment
    if n.mesh >= 0 do prims = model.meshes[n.mesh]
    if len(prims) > 0 {
      node.look = prims[0]
      if n.skin >= 0 do node.rig = max(skin_rigs[n.skin], -1)
    }
    template[i] = len(model.nodes)
    append(&model.nodes, node)
    // a mesh's further primitives, each with its own material, hang under the node
    for look in prims[min(1, len(prims)):] {
      append(&model.nodes, ModelNode{name = strings.clone(n.name), parent = template[i], transform = geometry.Transform{rotation = 1, scale = 1}, look = look, rig = node.rig})
    }
  }
  for s, skin in file.skins do if rig := skin_rigs[skin]; rig >= 0 {
    for joint, bone in s.joints do append(&model.joints, ModelJoint{node = template[joint], rig = RigHandle(rig), bone = u32(bone)})
  }
  return model, true
}

// model_destroy frees the model's render resources and rigs. Destroy its instances first.
model_destroy :: proc(self: ^Model, r: ^render.Renderer) {
  unload(self, r)
  for &rig in self.rigs do animation.rig_destroy(&rig)
  for n in self.nodes do delete(n.name)
  delete(self.rigs)
  delete(self.nodes)
  delete(self.joints)
  self^ = {}
}

// instance_create spawns one world node per glTF node of the model under `parent` (the world
// root by default), each drawing its mesh, and an animator per rig at its rest pose: play
// clips or add layers on them, and call animate each tick.
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
  instance.animators = make([]animation.Animator, len(model.rigs))
  instance.bones = make([]render.BonesHandle, len(model.rigs))
  for &rig, i in model.rigs {
    animation.animator_init(&instance.animators[i], &rig)
    instance.bones[i] = render.bones_create(r, u32(animation.bone_count(&rig.skeleton)))
  }
  nodes := make([]world.NodeHandle, len(model.nodes), context.temp_allocator)
  for n, i in model.nodes {
    handle := world.spawn(w, name = n.name, parent = root if n.parent < 0 else nodes[n.parent]) or_continue
    nodes[i] = handle
    world.set_local(w, handle, n.transform.position, n.transform.rotation, n.transform.scale)
    if n.parent < 0 do append(&instance.roots, handle)
    if n.light != 0 {
      // a light and a mesh share a slot only through a child node
      slot := handle
      if n.look.mesh != 0 do slot = world.spawn(w, parent = handle) or_continue
      render.attach(r, slot, n.light)
    }
    if n.look.mesh == 0 do continue
    look := n.look
    if n.rig >= 0 {
      look.bones = instance.bones[n.rig]
      append(&instance.skinned, SkinnedNode{node = handle, rig = RigHandle(n.rig)})
    }
    render.attach(r, handle, look)
  }
  for j in model.joints do if nodes[j.node] != {} {
    append(&instance.joints, Joint{node = nodes[j.node], rig = j.rig, bone = j.bone})
  }
  return instance, len(instance.roots) > 0
}

// animate advances each rig's animator by dt, poses the rig's joints (what hangs under them
// follows at the next world.update) and stages the palette of every skinned node, once per tick.
// WORLD-space layers are placed by the world matrix of the rig's first skinned node as of the
// last world.update: call it after world.update for this tick's.
animate :: proc(self: ^Instance, model: ^Model, w: ^world.World, r: ^render.Renderer, dt: f32) {
  for &a, i in self.animators {
    rig := RigHandle(i)
    root := linalg.MATRIX4F32_IDENTITY
    for s in self.skinned do if s.rig == rig {
      root = world.world_matrix(w, s.node)
      break
    }
    animation.animator_update(&a, &model.rigs[i], dt, root)
    pose_joints(self, w, model, rig, &a)
  }
  for &a, i in self.animators do render.stage_bones(r, self.bones[i], a.palette)
}

// instance_destroy destroys the instance's nodes (roots and their descendants) and animators.
instance_destroy :: proc(self: ^Instance, w: ^world.World, r: ^render.Renderer) {
  for h in self.roots do world.destroy(w, h)
  for &a in self.animators do animation.destroy(&a)
  for b in self.bones do render.destroy(r, b)
  delete(self.animators)
  delete(self.bones)
  delete(self.roots)
  delete(self.skinned)
  delete(self.joints)
  self^ = {}
}

// Moves the instance's joint nodes of `rig` to the animator's pose.
@(private = "file")
pose_joints :: proc(self: ^Instance, w: ^world.World, model: ^Model, rig: RigHandle, animator: ^animation.Animator) {
  skeleton := &model.rigs[rig].skeleton
  locals := make([]geometry.Transform, len(skeleton.parents), context.temp_allocator)
  animation.bone_locals(animator, skeleton, locals)
  for j in self.joints do if j.rig == rig {
    l := locals[j.bone]
    world.set_local(w, j.node, l.position, l.rotation, l.scale)
  }
}

// destroy frees a Model or an Instance, as model_destroy and instance_destroy do.
destroy :: proc {
  model_destroy,
  instance_destroy,
}
