#+build !js
#+private file
package animation

import "../asset"
import "core:testing"

// animation on its own: a rig from a model file, a clip sampled into a pose, an animator playing it.
@(test)
test_rig_from_model_file :: proc(t: ^testing.T) {
  model, ok := asset.load_gltf(#load("../../assets/CesiumMan.glb"))
  testing.expect(t, ok, "load")
  defer asset.destroy(&model)
  rig, built := rig_from(&model, 0)
  testing.expect(t, built, "rig")
  defer rig_destroy(&rig)
  n := bone_count(&rig.skeleton)
  testing.expect_value(t, n, 19)
  testing.expect(t, len(rig.clips) > 0 && rig.clips[0].duration > 0, "the file's animation becomes a clip")
  pose := make([]TRS, n, context.temp_allocator)
  copy(pose, rig.skeleton.rest)
  clip_sample(&rig.clips[0], rig.clips[0].duration * 0.5, pose)
  moved := false
  for p, i in pose do if p != rig.skeleton.rest[i] do moved = true
  testing.expect(t, moved, "mid-clip, some bone is off its rest pose")
  a: Animator
  testing.expect(t, animator_init(&a, &rig), "animator")
  defer animator_destroy(&a)
  play(&a, &rig, rig.clips[0].name)
  animator_update(&a, &rig, 0.5)
  locals := make([]TRS, n, context.temp_allocator)
  bone_locals(&a, &rig.skeleton, locals)
  testing.expect(t, len(a.palette) == n, "a palette per bone")
}
