package gltf

import anim "../animation"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "vendor:cgltf"

// load_rig builds a rig from a parsed glTF skin: its joint hierarchy as the skeleton,
// and every animation in `data` as a clip over those joints. Free with
// anim.rig_destroy.
load_rig :: proc(data: ^cgltf.data, skin: ^cgltf.skin) -> (rig: anim.Rig, ok: bool) {
  n := len(skin.joints)
  parents := make([]i32, n, context.temp_allocator)
  inverse_bind := make([]matrix[4, 4]f32, n, context.temp_allocator)
  names := make([]string, n, context.temp_allocator)
  for joint_node, i in skin.joints {
    names[i] = string(joint_node.name)
    parents[i] = -1
    if idx, found := slice.linear_search(skin.joints, joint_node.parent); found {
      parents[i] = i32(idx)
    }
    inverse_bind[i] = linalg.MATRIX4F32_IDENTITY
    if skin.inverse_bind_matrices != nil {
      read := cgltf.accessor_read_float(skin.inverse_bind_matrices, uint(i), auto_cast &inverse_bind[i], 16)
      if !read do log.warnf("could not load inverse bind matrices for bone #%v", i)
    }
  }
  if !anim.skeleton_init(&rig.skeleton, parents, inverse_bind, names) {
    log.warnf("invalid joint hierarchy in skin %v", skin.name)
    return {}, false
  }
  load_clips(data, skin, &rig)
  log.infof("Processed skin with %d bones, %d clips", n, len(rig.clips))
  return rig, true
}

// Read a sampler into temp arrays. CUBIC output carries 3 values per key.
@(private = "file")
read_sampler :: proc(
  $T: typeid,
  sampler: ^cgltf.animation_sampler,
) -> (
  times: []f32,
  values: []T,
  interpolation: anim.Interpolation,
) {
  times = make([]f32, sampler.input.count, context.temp_allocator)
  _ = cgltf.accessor_unpack_floats(sampler.input, raw_data(times), uint(len(times)))
  values = make([]T, sampler.output.count, context.temp_allocator)
  _ = cgltf.accessor_unpack_floats(sampler.output, auto_cast raw_data(values), uint(len(values) * size_of(T) / size_of(f32)))
  switch sampler.interpolation {
  case .linear:
    interpolation = .LINEAR
  case .step:
    interpolation = .STEP
  case .cubic_spline:
    interpolation = .CUBIC
  }
  return
}

@(private = "file")
load_clips :: proc(data: ^cgltf.data, skin: ^cgltf.skin, rig: ^anim.Rig) {
  for gltf_anim, i in data.animations {
    name := string(gltf_anim.name) if gltf_anim.name != nil else fmt.tprintf("animation_%d", i)
    clip: anim.Clip
    anim.clip_init(&clip, len(skin.joints), name)
    for gltf_channel in gltf_anim.channels do if gltf_channel.target_node != nil && gltf_channel.sampler != nil {
      bone := slice.linear_search(skin.joints, gltf_channel.target_node) or_continue
      #partial switch gltf_channel.target_path {
      case .translation:
        times, values, interp := read_sampler([3]f32, gltf_channel.sampler)
        anim.clip_set_positions(&clip, bone, times, values, interp)
      case .rotation:
        times, values, interp := read_sampler(quaternion128, gltf_channel.sampler)
        anim.clip_set_rotations(&clip, bone, times, values, interp)
      case .scale:
        times, values, interp := read_sampler([3]f32, gltf_channel.sampler)
        anim.clip_set_scales(&clip, bone, times, values, interp)
      }
    }
    append(&rig.clips, clip)
  }
}
