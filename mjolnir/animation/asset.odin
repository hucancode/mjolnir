package animation

import "../asset"
import "core:slice"

#assert(int(asset.Interpolation.LINEAR) == int(Interpolation.LINEAR) && int(asset.Interpolation.STEP) == int(Interpolation.STEP) && int(asset.Interpolation.CUBIC) == int(Interpolation.CUBIC))

// rig_from builds a rig from skin `skin` of model: its joints as the skeleton, at rest as the
// file poses them, and every clip of the model over those joints (channel i animates bone i).
// Free with rig_destroy.
rig_from :: proc(model: ^asset.Model, skin: int) -> (rig: Rig, ok: bool) #optional_ok {
  s := &model.skins[skin]
  names := make([]string, len(s.joints), context.temp_allocator)
  for j, i in s.joints do names[i] = model.nodes[j].name
  skeleton_init(&rig.skeleton, s.parents, s.inverse_bind, names, s.rest) or_return
  for c in model.clips {
    clip: Clip
    clip_init(&clip, len(s.joints), c.name)
    for ch in c.channels {
      bone := slice.linear_search(s.joints, ch.node) or_continue
      interpolation := Interpolation(ch.interpolation)
      switch ch.path {
      case .TRANSLATION:
        clip_set_positions(&clip, bone, ch.times, slice.reinterpret([][3]f32, ch.values), interpolation)
      case .ROTATION:
        clip_set_rotations(&clip, bone, ch.times, slice.reinterpret([]quaternion128, ch.values), interpolation)
      case .SCALE:
        clip_set_scales(&clip, bone, ch.times, slice.reinterpret([][3]f32, ch.values), interpolation)
      }
    }
    append(&rig.clips, clip)
  }
  return rig, true
}
