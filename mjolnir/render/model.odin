package render

import "../asset"
import "core:log"

// ModelLooks is what model_upload made of an asset.Model, by the model's indices: meshes[i]
// draws mesh i, one attachment per primitive (none for a mesh no node uses); materials[i] is
// material i; lights[i] is light i, 0 for a directional one (the scene's sun is Renderer.sun).
// textures are the images the materials sample.
ModelLooks :: struct {
  meshes:    [][]MeshAttachment,
  materials: []MaterialHandle,
  lights:    []LightHandle,
  textures:  [dynamic]TextureHandle,
}

// model_upload makes the meshes, materials, textures and lights of model; a primitive without a
// material draws white. Lights keep the file's units (lux, candela): scale them with light; a
// light without a range reaches 10. Free with model_looks_destroy.
model_upload :: proc(self: ^Renderer, model: ^asset.Model) -> (looks: ModelLooks, ok: bool) #optional_ok {
  guard(self)
  defer if !ok do model_looks_destroy(self, &looks)
  // per image: the texture as color (sRGB) data and as linear data
  images := make([][2]TextureHandle, len(model.images), context.temp_allocator)
  texture :: proc(self: ^Renderer, looks: ^ModelLooks, model: ^asset.Model, images: [][2]TextureHandle, image: int, srgb: bool) -> (handle: TextureHandle, ok: bool) {
    if image < 0 || len(model.images[image]) == 0 do return NO_TEXTURE, true
    h := &images[image][int(srgb)]
    if h^ == NO_TEXTURE {
      h^ = texture_create(self, model.images[image], .RGBA8_SRGB if srgb else .RGBA8_UNORM) or_return
      append(&looks.textures, h^)
    }
    return h^, true
  }
  looks.materials = make([]MaterialHandle, len(model.materials))
  for m, i in model.materials {
    albedo := texture(self, &looks, model, images, m.textures[.ALBEDO], true) or_return
    metallic_roughness := texture(self, &looks, model, images, m.textures[.METALLIC_ROUGHNESS], false) or_return
    normal := texture(self, &looks, model, images, m.textures[.NORMAL], false) or_return
    emissive := texture(self, &looks, model, images, m.textures[.EMISSIVE], true) or_return
    looks.materials[i] = material_create(self, make_material(.PBR, albedo, metallic_roughness, normal, emissive, m.metallic, m.roughness, m.emissive, m.base_color)) or_return
  }
  looks.meshes = make([][]MeshAttachment, len(model.meshes))
  for prims, i in model.meshes {
    look := make([]MeshAttachment, len(prims))
    looks.meshes[i] = look
    for p, j in prims {
      material := self.builtin_materials[.WHITE] if p.material < 0 else looks.materials[p.material]
      look[j] = {mesh = mesh_upload(self, p.mesh) or_return, material = material, cast_shadow = true}
    }
  }
  looks.lights = make([]LightHandle, len(model.lights))
  for l, i in model.lights {
    reach := l.range if l.range > 0 else 10
    light: Light
    switch l.type {
    case .DIRECTIONAL:
      continue
    case .POINT:
      light = make_point_light(l.color, l.intensity, reach)
    case .SPOT:
      light = make_spot_light(l.color, l.intensity, reach, l.outer_angle)
      light.angle_inner = l.inner_angle
    }
    looks.lights[i] = light_create(self, light) or_return
  }
  log.infof("Model: %d meshes, %d materials, %d textures, %d lights", len(model.meshes), len(model.materials), len(looks.textures), len(model.lights))
  return looks, true
}

// model_looks_destroy frees what model_upload made.
model_looks_destroy :: proc(self: ^Renderer, looks: ^ModelLooks) {
  for look in looks.meshes {
    for a in look do mesh_destroy(self, a.mesh)
    delete(look)
  }
  for h in looks.materials do material_destroy(self, h)
  for h in looks.lights do light_destroy(self, h)
  for h in looks.textures do texture_destroy(self, h)
  delete(looks.meshes)
  delete(looks.materials)
  delete(looks.lights)
  delete(looks.textures)
  looks^ = {}
}
