package mjolnir

import "core:fmt"
import "base:runtime"
import linalg "core:math/linalg"
import "core:strings"
import "geometry"
import "resource"
import vk "vendor:vulkan"

Bone :: struct {
  bind_transform:      geometry.Transform,
  children:            []u32,
  inverse_bind_matrix: linalg.Matrix4f32,
  name:                string, // Optional: for debugging or lookup
}

bone_deinit :: proc(bone: ^Bone) {
  if bone.children != nil {
    // delete(bone.children)
    bone.children = nil
  }
}

SkeletalMesh :: struct {
  root_bone_index:      u32, // Index of the root bone in the 'bones' array
  bones:                []Bone,
  animations:           []Animation_Clip, // Animation clips
  vertices_len:         u32,
  indices_len:          u32,
  vertex_buffer:        DataBuffer,
  simple_vertex_buffer: DataBuffer, // For shadow passes (positions only)
  index_buffer:         DataBuffer,
  material:             Handle, // Handle to a SkinnedMaterial resource
  aabb:                 geometry.Aabb,
  ctx_ref:              ^VulkanContext, // For deinitializing buffers
}

// deinit_skeletal_mesh releases Vulkan buffers and other owned memory.
skeletal_mesh_deinit :: proc(self: ^SkeletalMesh) {
  if self.ctx_ref == nil {
    return // Not initialized or already deinitialized
  }
  vkd := self.ctx_ref.vkd

  if self.vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.vertex_buffer, self.ctx_ref)
  }
  if self.simple_vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.simple_vertex_buffer, self.ctx_ref)
  }
  if self.index_buffer.buffer != 0 {
    data_buffer_deinit(&self.index_buffer, self.ctx_ref)
  }

  // Deinitialize bones
  if self.bones != nil {
    for &bone, _ in self.bones {
      bone_deinit(&bone)
    }
    delete(self.bones)
    self.bones = nil
  }

  // Deinitialize animations (Clips)
  if self.animations != nil {
    for &anim_clip, _ in self.animations {
      // deinit_clip(&anim_clip)
    }
    delete(self.animations)
    self.animations = nil
  }

  self.ctx_ref = nil
}

// init_skeletal_mesh initializes the mesh, creates Vulkan buffers.
skeletal_mesh_init :: proc(
  self: ^SkeletalMesh,
  geometry_data: ^geometry.SkinnedGeometry,
  ctx: ^VulkanContext,
) -> vk.Result {
  self.ctx_ref = ctx
  self.vertices_len = u32(len(geometry_data.vertices))
  self.indices_len = u32(len(geometry_data.indices))
  self.aabb = geometry_data.aabb
  positions_slice := geometry.extract_positions_skinned_geometry(geometry_data)
  size := len(positions_slice) * size_of(linalg.Vector4f32)
  self.simple_vertex_buffer = create_local_buffer(
    ctx,
    raw_data(positions_slice),
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
  ) or_return
  size = len(geometry_data.vertices) * size_of(geometry.SkinnedVertex)
  self.vertex_buffer = create_local_buffer(
    ctx,
    raw_data(geometry_data.vertices),
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
  ) or_return
  size = len(geometry_data.indices) * size_of(u32)
  self.index_buffer = create_local_buffer(
    ctx,
    raw_data(geometry_data.indices),
    vk.DeviceSize(size),
    {.INDEX_BUFFER},
  ) or_return
  self.bones = make([]Bone, 0)
  self.animations = make([]Animation_Clip, 0)
  return .SUCCESS
}

// play_animation finds an animation by name and returns an Instance.
play_animation :: proc(
  self: ^SkeletalMesh,
  animation_name: string,
  mode: Animation_Play_Mode,
  speed: f32 = 1.0,
) -> (
  instance: Animation_Instance,
  found: bool,
) {
  for clip, i in self.animations {
    if clip.name == animation_name {
      found = true
      instance = {
        clip_handle = u32(i),
        mode        = mode,
        status      = .Playing,
        time        = 0.0,
        duration    = clip.duration,
        speed       = speed,
      }
      return
    }
  }
  found = false
  return
}

// calculate_animation_transform computes the bone matrices for the given animation instance and pose.
calculate_animation_transform :: proc(
  self: ^SkeletalMesh,
  anim_instance: ^Animation_Instance,
  target_pose: ^Pose,
) {
  if anim_instance.status == .Stopped ||
     anim_instance.clip_handle >= u32(len(self.animations)) {
    return
  }
  if len(target_pose.bone_matrices) < len(self.bones) {
    return
  }
  transform_stack := make([dynamic]linalg.Matrix4f32, 0, len(self.bones))
  bone_stack := make([dynamic]u32, 0, len(self.bones))
  defer {
    delete(transform_stack)
    delete(bone_stack)
  }

  append(&transform_stack, linalg.MATRIX4F32_IDENTITY)
  append(&bone_stack, u32(self.root_bone_index))

  active_clip := &self.animations[anim_instance.clip_handle]

  for len(bone_stack) > 0 {
    current_bone_index := pop(&bone_stack)
    parent_world_transform := pop(&transform_stack)
    current_bone := &self.bones[current_bone_index]
    local_animated_transform := geometry.transform_identity()
    if current_bone_index < u32(len(active_clip.channels)) {
      channel := &active_clip.channels[current_bone_index]
      animation_channel_calculate(
        channel,
        anim_instance.time,
        &local_animated_transform,
      )
    } else {
      local_animated_transform = current_bone.bind_transform
    }
    local_matrix := linalg.matrix4_from_trs_f32(local_animated_transform.position, local_animated_transform.rotation, local_animated_transform.scale)
    current_world_transform := parent_world_transform * local_matrix
    // fmt.printfln("calculate_animation_transform, local matrix", local_matrix)
    target_pose.bone_matrices[current_bone_index] =
      current_world_transform * current_bone.inverse_bind_matrix
    for child_index in current_bone.children {
      append(&transform_stack, current_world_transform)
      append(&bone_stack, child_index)
    }
  }
  pose_flush(target_pose)
}
