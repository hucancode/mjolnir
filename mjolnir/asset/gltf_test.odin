#+build !js
#+private file
package asset

import "core:testing"

@(test)
test_load_skinned_gltf :: proc(t: ^testing.T) {
  model, ok := load_gltf(#load("../../assets/CesiumMan.glb"))
  testing.expect(t, ok, "load")
  defer model_destroy(&model)
  testing.expect_value(t, len(model.skins), 1)
  testing.expect_value(t, len(model.skins[0].joints), 19)
  testing.expect(t, len(model.clips) > 0 && len(model.clips[0].channels) > 0, "an animation with channels")
  skinned := 0
  for n in model.nodes do if n.mesh >= 0 && n.skin >= 0 {
    skinned += 1
    prim := model.meshes[n.mesh][0]
    testing.expect(t, len(prim.mesh.skinnings) == len(prim.mesh.vertices), "skinned meshes carry skinning data")
  }
  testing.expect_value(t, skinned, 1)
  for n, i in model.nodes do testing.expectf(t, n.parent < i, "node %d's parent %d comes first", i, n.parent)
  for j in model.skins[0].joints do testing.expect(t, j >= 0 && j < len(model.nodes), "joints index nodes")
  testing.expect(t, len(model.images) > 0 && len(model.images[0]) > 0, "embedded images are copied")
}
