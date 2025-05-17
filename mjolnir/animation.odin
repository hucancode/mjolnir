package mjolnir

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:sort"
import "geometry"
import vk "vendor:vulkan"

Vec3 :: linalg.Vector3f32
Quat :: linalg.Quaternionf32
EPSILON :: 1e-6

Keyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

// Sample a value from Keyframe_Quat at a specific time
keyframe_sample :: proc($T: typeid, frames: []Keyframe(T), t: f32) -> T {
  if len(frames) == 0 {
    return T{}
  }
  if t - frames[0].time < EPSILON {
    // fmt.printfln("sample_keyframe take first: %v", frames[0])
    return frames[0].value
  }
  if t >= frames[len(frames) - 1].time {
    // fmt.printfln("sample_keyframe take last: %v", frames[len(frames) - 1])
    return frames[len(frames) - 1].value
  }

  i, found := slice.binary_search_by(
    frames,
    t,
    proc(item: Keyframe(T), t: f32) -> slice.Ordering {
      if item.time < t {
        return slice.Ordering.Less
      }
      return slice.Ordering.Greater
    },
  )
  a := frames[i - 1]
  b := frames[i]
  if b.time - a.time < EPSILON {
    return a.value
  }
  alpha := (t - a.time) / (b.time - a.time)
  // fmt.printfln("sample_keyframe: (%v %v) %v", a, b, alpha)
  return linalg.lerp(a.value, b.value, alpha)
}

Animation_Status :: enum {
  Playing,
  Paused,
  Stopped,
}

Animation_Play_Mode :: enum {
  Loop,
  Once,
  Ping_Pong,
}

Pose :: struct {
  bone_matrices: []linalg.Matrix4f32, // for CPU, we update this to define the pose of the mesh
  bone_buffer:   DataBuffer, // for GPU, we upload data to the GPU so the shader can actually animate the mesh
  vk_ctx_ref:    ^VulkanContext,
}

pose_init :: proc(
  pose: ^Pose,
  joints_count: int,
  vk_ctx: ^VulkanContext,
) -> vk.Result {
  fmt.printfln("init_pose: joints_count %d", joints_count)
  pose.vk_ctx_ref = vk_ctx
  pose.bone_matrices = make([]linalg.Matrix4f32, joints_count)
  for &m in pose.bone_matrices {
    m = linalg.MATRIX4F32_IDENTITY
  }
  buffer_size := size_of(linalg.Matrix4f32) * vk.DeviceSize(joints_count)
  pose.bone_buffer = create_host_visible_buffer(
    vk_ctx,
    buffer_size,
    {.STORAGE_BUFFER},
  ) or_return
  // fmt.printfln("init_pose success: bone_buffer %v", pose.bone_buffer)
  return .SUCCESS
}

pose_deinit :: proc(pose: ^Pose) {
  data_buffer_deinit(&pose.bone_buffer, pose.vk_ctx_ref)
  if pose.bone_matrices != nil {
    delete(pose.bone_matrices)
    pose.bone_matrices = nil
  }
}

pose_flush :: proc(pose: ^Pose) -> vk.Result {
  if pose.bone_matrices == nil {
    return .SUCCESS
  }
  size := size_of(linalg.Matrix4f32) * vk.DeviceSize(len(pose.bone_matrices))
  // fmt.printfln("flush_pose: buffer size %d bytes, matrices size %d bytes %v", pose.bone_buffer.size, size, pose.bone_matrices)
  data_buffer_write(
    &pose.bone_buffer,
    raw_data(pose.bone_matrices),
    size,
  ) or_return
  return .SUCCESS
}

Animation_Instance :: struct {
  clip_handle: u32,
  mode:        Animation_Play_Mode,
  status:      Animation_Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

// Initialize an animation instance
animation_instance_init :: proc(instance: ^Animation_Instance, clip: u32) {
  instance.clip_handle = clip
  instance.mode = .Loop
  instance.status = .Stopped
  instance.time = 0.0
  instance.speed = 1.0
}

animation_instance_pause :: proc(instance: ^Animation_Instance) {
  instance.status = .Paused
}

animation_instance_play :: proc(instance: ^Animation_Instance) {
  instance.status = .Playing
}

animation_instance_toggle :: proc(instance: ^Animation_Instance) {
  switch instance.status {
  case .Playing:
    animation_instance_pause(instance)
  case .Paused:
    animation_instance_play(instance)
  case .Stopped:
    instance.time = 0
    animation_instance_play(instance)
  }
}

animation_instance_stop :: proc(instance: ^Animation_Instance) {
  instance.status = .Stopped
  instance.time = 0
}

// Update animation instance time. Needs clip_duration.
animation_instance_update :: proc(
  instance: ^Animation_Instance,
  delta_time: f32,
) {
  if instance.status != .Playing || instance.duration <= 0 {
    // return
  }

  instance.mode = .Loop

  effective_delta_time := delta_time * instance.speed

  switch instance.mode {
  case .Loop:
    instance.time += effective_delta_time
    instance.time = math.mod_f32(
      instance.time + instance.duration,
      instance.duration,
    )
  // fmt.printfln("animation_instance_update: time +%f = %f", effective_delta_time, instance.time)
  case .Once:
    instance.time += effective_delta_time
    instance.time = math.mod_f32(
      instance.time + instance.duration,
      instance.duration,
    )
    if instance.time >= instance.duration {
      instance.time = instance.duration
      instance.status = .Stopped
    }
  case .Ping_Pong:
    instance.time += effective_delta_time
    if instance.time >= instance.duration || instance.time < 0 {
      instance.speed *= -1
    }
  }
}


Animation_Channel :: struct {
  position_keyframes: []Keyframe(Vec3),
  rotation_keyframes: []Keyframe(Quat),
  scale_keyframes:    []Keyframe(Vec3),
}

animation_channel_deinit :: proc(channel: ^Animation_Channel) {
  if channel.position_keyframes != nil {
    delete(channel.position_keyframes)
    channel.position_keyframes = nil
  }
  if channel.rotation_keyframes != nil {
    delete(channel.rotation_keyframes)
    channel.rotation_keyframes = nil
  }
  if channel.scale_keyframes != nil {
    delete(channel.scale_keyframes)
    channel.scale_keyframes = nil
  }
}

animation_channel_calculate :: proc(
  channel: ^Animation_Channel,
  t: f32,
  output_transform: ^geometry.Transform,
) {
  if len(channel.position_keyframes) > 0 {
    output_transform.position = keyframe_sample(
      Vec3,
      channel.position_keyframes,
      t,
    )
  }
  if len(channel.rotation_keyframes) > 0 {
    output_transform.rotation = keyframe_sample(
      Quat,
      channel.rotation_keyframes,
      t,
    )
    // fmt.printfln("sample_keyframe rotation: time %f rotation quat %v", t, output_transform.rotation)
  }
  if len(channel.scale_keyframes) > 0 {
    output_transform.scale = keyframe_sample(Vec3, channel.scale_keyframes, t)
  }
  output_transform.is_dirty = true
}


Animation_Clip :: struct {
  name:     string,
  duration: f32,
  channels: []Animation_Channel,
}

animation_clip_deinit :: proc(clip: ^Animation_Clip) {
  if clip.channels != nil {
    for &channel in clip.channels {
      animation_channel_deinit(&channel)
    }
    delete(clip.channels)
    clip.channels = nil
  }
}
