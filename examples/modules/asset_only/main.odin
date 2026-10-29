// Asset on its own: a glTF inspector printing a model's node tree, meshes, materials, skins, clips and lights; pass a .glb path, CesiumMan by default.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "mjolnir/asset"

main :: proc() {
  path := os.args[1] if len(os.args) > 1 else "assets/CesiumMan.glb"
  data, err := os.read_entire_file(path, context.allocator)
  if err != nil {
    fmt.eprintfln("cannot read %s: %v", path, err)
    os.exit(1)
  }
  defer delete(data)
  model, ok := asset.load_gltf(data)
  if !ok {
    fmt.eprintfln("%s is not a self-contained glTF", path)
    os.exit(1)
  }
  defer asset.destroy(&model)
  fmt.printfln("%s: %d nodes, %d meshes, %d materials, %d images, %d skins, %d clips, %d lights", path, len(model.nodes), len(model.meshes), len(model.materials), len(model.images), len(model.skins), len(model.clips), len(model.lights))

  fmt.println("\nnodes")
  for n, i in model.nodes do if n.parent < 0 do print_node(&model, i, 1)

  fmt.println("\nmeshes")
  for prims, i in model.meshes {
    vertices, triangles, skinned := 0, 0, false
    for p in prims {
      vertices += len(p.mesh.vertices)
      triangles += len(p.mesh.indices) / 3
      skinned ||= len(p.mesh.skinnings) > 0
    }
    fmt.printfln("  %d: %d primitives, %d vertices, %d triangles%s", i, len(prims), vertices, triangles, ", skinned" if skinned else "")
  }

  fmt.println("\nmaterials")
  for m, i in model.materials {
    fmt.printf("  %d: base %v metallic %.2f roughness %.2f", i, m.base_color, m.metallic, m.roughness)
    for image, slot in m.textures do if image >= 0 do fmt.printf(" %v=image %d", slot, image)
    fmt.println()
  }

  if len(model.skins) > 0 do fmt.println("\nskins")
  for s, i in model.skins do fmt.printfln("  %d %q: %d joints, root %q", i, s.name, len(s.joints), model.nodes[s.joints[0]].name)

  if len(model.clips) > 0 do fmt.println("\nclips")
  for c in model.clips {
    duration := f32(0)
    for ch in c.channels do if len(ch.times) > 0 do duration = max(duration, slice.last(ch.times))
    fmt.printfln("  %q: %.2fs, %d channels", c.name, duration, len(c.channels))
  }

  if len(model.lights) > 0 do fmt.println("\nlights")
  for l, i in model.lights do fmt.printfln("  %d: %v color %v intensity %.1f range %.1f", i, l.type, l.color, l.intensity, l.range)
}

print_node :: proc(model: ^asset.Model, i: int, depth: int) {
  n := model.nodes[i]
  what := ""
  if n.mesh >= 0 do what = fmt.tprintf(" mesh %d", n.mesh)
  if n.skin >= 0 do what = fmt.tprintf("%s skin %d", what, n.skin)
  if n.light >= 0 do what = fmt.tprintf("%s light %d", what, n.light)
  fmt.printfln("%*s%s%s", depth * 2, "", n.name if n.name != "" else "(unnamed)", what)
  for c, k in model.nodes do if c.parent == i do print_node(model, k, depth + 1)
}
