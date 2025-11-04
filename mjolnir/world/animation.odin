package world

import anim "../animation"
import cont "../containers"
import "../geometry"
import "../gpu"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

animation_instance_update :: proc(self: ^AnimationInstance, delta_time: f32) {
  if self.status != .PLAYING || self.duration <= 0 {
    return
  }
  effective_delta_time := delta_time * self.speed
  switch self.mode {
  case .LOOP:
    self.time += effective_delta_time
    self.time = math.mod_f32(self.time + self.duration, self.duration)
  case .ONCE:
    self.time += effective_delta_time
    self.time = math.mod_f32(self.time + self.duration, self.duration)
    if self.time >= self.duration {
      self.time = self.duration
      self.status = .STOPPED
    }
  case .PING_PONG:
    self.time += effective_delta_time
    if self.time >= self.duration || self.time < 0 {
      self.speed *= -1
    }
  }
}

update_skeletal_animations :: proc(
  world: ^World,
  rm: ^resources.Manager,
  delta_time: f32,
) {
  if delta_time <= 0 do return
  bone_buffer := &rm.bone_buffer
  if bone_buffer.mapped == nil do return
  for handle in world.animatable_nodes {
    node := cont.get(world.nodes, handle) or_continue
    mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
    if !has_mesh do continue
    skinning, has_skin := &mesh_attachment.skinning.?
    if !has_skin do continue
    if len(skinning.layers) == 0 do continue
    mesh := cont.get(rm.meshes, mesh_attachment.handle) or_continue
    mesh_skinning, mesh_has_skin := mesh.skinning.?
    if !mesh_has_skin do continue
    bone_count := len(mesh_skinning.bones)
    if bone_count == 0 do continue
    if skinning.bone_matrix_buffer_offset == 0xFFFFFFFF do continue
    for &layer in skinning.layers {
      anim.layer_update(&layer, delta_time)
    }
    matrices_ptr := gpu.mutable_buffer_get(
      bone_buffer,
      skinning.bone_matrix_buffer_offset,
    )
    matrices := slice.from_ptr(matrices_ptr, bone_count)
    resources.sample_layers(
      mesh,
      rm,
      skinning.layers[:],
      nil,
      matrices,
    )
  }
}

// Update all node animations (generic node transform animations)
// This animates the node's local transform (position, rotation, scale)
// Works for any node type: lights, static meshes, cameras, etc.
update_node_animations :: proc(
  world: ^World,
  rm: ^resources.Manager,
  delta_time: f32,
) {
  if delta_time <= 0 do return
  for handle in world.animatable_nodes {
    node := cont.get(world.nodes, handle) or_continue
    anim_inst, has_anim := &node.animation.?
    if !has_anim do continue
    clip, clip_ok := cont.get(rm.animation_clips, anim_inst.clip_handle)
    if !clip_ok do continue
    animation_instance_update(anim_inst, delta_time)
    if len(clip.channels) > 0 {
      position, rotation, scale := anim.channel_sample_some(
        clip.channels[0],
        anim_inst.time,
      )
      if pos, has_pos := position.?; has_pos {
        node.transform.position = pos
        node.transform.is_dirty = true
      }
      if rot, has_rot := rotation.?; has_rot {
        node.transform.rotation = rot
        node.transform.is_dirty = true
      }
      if scl, has_scl := scale.?; has_scl {
        node.transform.scale = scl
        node.transform.is_dirty = true
      }
    }
  }
}

// Update all sprite animations
update_sprite_animations :: proc(rm: ^resources.Manager, delta_time: f32) {
  if delta_time <= 0 do return

  for handle in rm.animatable_sprites {
    sprite := cont.get(rm.sprites, handle) or_continue
    anim_inst, has_anim := &sprite.animation.?
    if !has_anim do continue
    resources.sprite_animation_update(anim_inst, delta_time)
    resources.sprite_write_to_gpu(rm, handle, sprite)
  }
}

