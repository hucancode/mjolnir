#+build !js
#+private file
package gltf

import "../animation"
import "../asset"
import "../geometry"
import "core:testing"

// a rig from a model file, a clip sampled into a pose, an animator playing it.
@(test)
test_rig_from_model_file :: proc(t: ^testing.T) {
  model, ok := asset.load_gltf(#load("../../assets/CesiumMan.glb"))
  testing.expect(t, ok, "load")
  defer asset.destroy(&model)
  rig, built := rig_from(&model, 0)
  testing.expect(t, built, "rig")
  defer animation.rig_destroy(&rig)
  n := animation.bone_count(&rig.skeleton)
  testing.expect_value(t, n, 19)
  testing.expect(t, len(rig.clips) > 0 && rig.clips[0].duration > 0, "the file's animation becomes a clip")
  pose := make([]geometry.Transform, n, context.temp_allocator)
  copy(pose, rig.skeleton.rest)
  animation.clip_sample(&rig.clips[0], rig.clips[0].duration * 0.5, pose)
  moved := false
  for p, i in pose do if p != rig.skeleton.rest[i] do moved = true
  testing.expect(t, moved, "mid-clip, some bone is off its rest pose")
  a: animation.Animator
  testing.expect(t, animation.animator_init(&a, &rig), "animator")
  defer animation.animator_destroy(&a)
  animation.play(&a, &rig, rig.clips[0].name)
  animation.animator_update(&a, &rig, 0.5)
  locals := make([]geometry.Transform, n, context.temp_allocator)
  animation.bone_locals(&a, &rig.skeleton, locals)
  testing.expect(t, len(a.palette) == n, "a palette per bone")
}
