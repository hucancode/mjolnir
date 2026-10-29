// Asset on its own: a glTF inspector reporting a model's node tree, meshes, materials, skins, clips and lights. The command line inspects the .glb given as its argument, CesiumMan by default; the web page inspects CesiumMan.
package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "mjolnir/asset"

DEFAULT :: "assets/CesiumMan.glb"

// inspect parses a self-contained glTF and describes what it holds.
inspect :: proc(name: string, data: []u8) -> (report: string, ok: bool) {
  model := asset.load_gltf(data) or_return
  defer asset.destroy(&model)
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, "%s: %d nodes, %d meshes, %d materials, %d images, %d skins, %d clips, %d lights", name, len(model.nodes), len(model.meshes), len(model.materials), len(model.images), len(model.skins), len(model.clips), len(model.lights))

  fmt.sbprintln(&b, "\nnodes")
  for n, i in model.nodes do if n.parent < 0 do print_node(&b, &model, i, 1)

  fmt.sbprintln(&b, "\nmeshes")
  for prims, i in model.meshes {
    vertices, triangles, skinned := 0, 0, false
    for p in prims {
      vertices += len(p.mesh.vertices)
      triangles += len(p.mesh.indices) / 3
      skinned ||= len(p.mesh.skinnings) > 0
    }
    fmt.sbprintfln(&b, "  %d: %d primitives, %d vertices, %d triangles%s", i, len(prims), vertices, triangles, ", skinned" if skinned else "")
  }

  fmt.sbprintln(&b, "\nmaterials")
  for m, i in model.materials {
    fmt.sbprintf(&b, "  %d: base %v metallic %.2f roughness %.2f", i, m.base_color, m.metallic, m.roughness)
    for image, slot in m.textures do if image >= 0 do fmt.sbprintf(&b, " %v=image %d", slot, image)
    fmt.sbprintln(&b)
  }

  if len(model.skins) > 0 do fmt.sbprintln(&b, "\nskins")
  for s, i in model.skins do fmt.sbprintfln(&b, "  %d %q: %d joints, root %q", i, s.name, len(s.joints), model.nodes[s.joints[0]].name)

  if len(model.clips) > 0 do fmt.sbprintln(&b, "\nclips")
  for c in model.clips {
    duration := f32(0)
    for ch in c.channels do if len(ch.times) > 0 do duration = max(duration, slice.last(ch.times))
    fmt.sbprintfln(&b, "  %q: %.2fs, %d channels", c.name, duration, len(c.channels))
  }

  if len(model.lights) > 0 do fmt.sbprintln(&b, "\nlights")
  for l, i in model.lights do fmt.sbprintfln(&b, "  %d: %v color %v intensity %.1f range %.1f", i, l.type, l.color, l.intensity, l.range)
  return strings.to_string(b), true
}

print_node :: proc(b: ^strings.Builder, model: ^asset.Model, i: int, depth: int) {
  n := model.nodes[i]
  what := ""
  if n.mesh >= 0 do what = fmt.tprintf(" mesh %d", n.mesh)
  if n.skin >= 0 do what = fmt.tprintf("%s skin %d", what, n.skin)
  if n.light >= 0 do what = fmt.tprintf("%s light %d", what, n.light)
  fmt.sbprintfln(b, "%*s%s%s", depth * 2, "", n.name if n.name != "" else "(unnamed)", what)
  for c, k in model.nodes do if c.parent == i do print_node(b, model, k, depth + 1)
}
