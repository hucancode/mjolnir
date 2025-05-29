package animation

import "../geometry"
import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

EPSILON :: 1e-6

Keyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

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

  i, _ := slice.binary_search_by(
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

Status :: enum {
  PLAYING,
  PAUSED,
  STOPPED,
}

PlayMode :: enum {
  LOOP,
  ONCE,
  PING_PONG,
}

Pose :: struct {
  bone_matrices: []linalg.Matrix4f32,
}

pose_init :: proc(pose: ^Pose, joints_count: int) {
  fmt.printfln("init_pose: joints_count %d", joints_count)
  pose.bone_matrices = make([]linalg.Matrix4f32, joints_count)
  return
}

pose_deinit :: proc(pose: ^Pose) {
  if pose.bone_matrices != nil {
    delete(pose.bone_matrices)
    pose.bone_matrices = nil
  }
}

pose_flush :: proc(pose: ^Pose, destination: rawptr) {
  if pose.bone_matrices == nil {
    return
  }
  size := size_of(linalg.Matrix4f32) * vk.DeviceSize(len(pose.bone_matrices))
  mem.copy(destination, raw_data(pose.bone_matrices), int(size))
  return
}

Instance :: struct {
  clip_handle: u32,
  mode:        PlayMode,
  status:      Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

instance_init :: proc(instance: ^Instance, clip: u32) {
  instance.clip_handle = clip
  instance.mode = .LOOP
  instance.status = .STOPPED
  instance.time = 0.0
  instance.speed = 1.0
}

instance_pause :: proc(instance: ^Instance) {
  instance.status = .PAUSED
}

instance_play :: proc(instance: ^Instance) {
  instance.status = .PLAYING
}

instance_toggle :: proc(instance: ^Instance) {
  switch instance.status {
  case .PLAYING:
    instance_pause(instance)
  case .PAUSED:
    instance_play(instance)
  case .STOPPED:
    instance.time = 0
    instance_play(instance)
  }
}

instance_stop :: proc(instance: ^Instance) {
  instance.status = .STOPPED
  instance.time = 0
}

instance_update :: proc(instance: ^Instance, delta_time: f32) {
  if instance.status != .PLAYING || instance.duration <= 0 {
    return
  }
  effective_delta_time := delta_time * instance.speed
  switch instance.mode {
  case .LOOP:
    instance.time += effective_delta_time
    instance.time = math.mod_f32(
      instance.time + instance.duration,
      instance.duration,
    )
  // fmt.printfln("animation_instance_update: time +%f = %f", effective_delta_time, instance.time)
  case .ONCE:
    instance.time += effective_delta_time
    instance.time = math.mod_f32(
      instance.time + instance.duration,
      instance.duration,
    )
    if instance.time >= instance.duration {
      instance.time = instance.duration
      instance.status = .STOPPED
    }
  case .PING_PONG:
    instance.time += effective_delta_time
    if instance.time >= instance.duration || instance.time < 0 {
      instance.speed *= -1
    }
  }
}

Channel :: struct {
  position_keyframes: []Keyframe(linalg.Vector3f32),
  rotation_keyframes: []Keyframe(linalg.Quaternionf32),
  scale_keyframes:    []Keyframe(linalg.Vector3f32),
}

channel_deinit :: proc(channel: ^Channel) {
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

channel_calculate :: proc(
  channel: ^Channel,
  t: f32,
  output_transform: ^geometry.Transform,
) {
  if len(channel.position_keyframes) > 0 {
    output_transform.position = keyframe_sample(
      linalg.Vector3f32,
      channel.position_keyframes,
      t,
    )
  }
  if len(channel.rotation_keyframes) > 0 {
    output_transform.rotation = keyframe_sample(
      linalg.Quaternionf32,
      channel.rotation_keyframes,
      t,
    )
    // fmt.printfln("sample_keyframe rotation: time %f rotation quat %v", t, output_transform.rotation)
  }
  if len(channel.scale_keyframes) > 0 {
    output_transform.scale = keyframe_sample(
      linalg.Vector3f32,
      channel.scale_keyframes,
      t,
    )
  }
  output_transform.is_dirty = true
}

Clip :: struct {
  name:     string,
  duration: f32,
  channels: []Channel,
}

clip_deinit :: proc(clip: ^Clip) {
  if clip.channels != nil {
    for &channel in clip.channels {
      channel_deinit(&channel)
    }
    delete(clip.channels)
    clip.channels = nil
  }
}
