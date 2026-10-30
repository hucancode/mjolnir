package gltf

import "../animation"
import "../asset"
import "../geometry"
import "../render"
import "core:log"
import "core:slice"

#assert(int(asset.Interpolation.LINEAR) == int(animation.Interpolation.LINEAR) && int(asset.Interpolation.STEP) == int(animation.Interpolation.STEP) && int(asset.Interpolation.CUBIC) == int(animation.Interpolation.CUBIC))

// Makes the meshes (taken from file), materials, textures and lights of file; a primitive
// without a material draws white. Lights keep the file's units (lux, candela); a light without
// a range reaches 10, a directional one is left out (the scene's sun is render's).
@(private)
upload :: proc(self: ^Model, r: ^render.Renderer, file: ^asset.Model) -> bool {
  render.lock(r)
  // per image: the texture as color (sRGB) data and as linear data
  images := make([][2]render.TextureHandle, len(file.images), context.temp_allocator)
  texture :: proc(self: ^Model, r: ^render.Renderer, file: ^asset.Model, images: [][2]render.TextureHandle, image: int, srgb: bool) -> (handle: render.TextureHandle, ok: bool) {
    if image < 0 || len(file.images[image]) == 0 do return render.NO_TEXTURE, true
    h := &images[image][int(srgb)]
    if h^ == render.NO_TEXTURE {
      h^ = render.texture_create(r, file.images[image], .RGBA8_SRGB if srgb else .RGBA8_UNORM) or_return
      append(&self.textures, h^)
    }
    return h^, true
  }
  self.materials = make([]render.MaterialHandle, len(file.materials))
  for m, i in file.materials {
    albedo := texture(self, r, file, images, m.textures[.ALBEDO], true) or_return
    metallic_roughness := texture(self, r, file, images, m.textures[.METALLIC_ROUGHNESS], false) or_return
    normal := texture(self, r, file, images, m.textures[.NORMAL], false) or_return
    emissive := texture(self, r, file, images, m.textures[.EMISSIVE], true) or_return
    self.materials[i] = render.material_create(r, render.make_material(.PBR, albedo, metallic_roughness, normal, emissive, m.metallic, m.roughness, m.emissive, m.base_color)) or_return
  }
  self.meshes = make([][]render.MeshAttachment, len(file.meshes))
  for &prims, i in file.meshes {
    look := make([]render.MeshAttachment, len(prims))
    self.meshes[i] = look
    for &p, j in prims {
      material := r.builtin_materials[.WHITE] if p.material < 0 else self.materials[p.material]
      mesh := p.mesh
      p.mesh = {}
      look[j] = {mesh = render.mesh_create(r, mesh) or_return, material = material, cast_shadow = true}
    }
  }
  self.lights = make([]render.LightHandle, len(file.lights))
  for l, i in file.lights {
    reach := l.range if l.range > 0 else 10
    light: render.Light
    switch l.type {
    case .DIRECTIONAL:
      continue
    case .POINT:
      light = render.make_point_light(l.color, l.intensity, reach)
    case .SPOT:
      light = render.make_spot_light(l.color, l.intensity, reach, l.outer_angle)
      light.angle_inner = l.inner_angle
    }
    self.lights[i] = render.light_create(r, light) or_return
  }
  log.infof("Model: %d meshes, %d materials, %d textures, %d lights", len(file.meshes), len(file.materials), len(self.textures), len(file.lights))
  return true
}

// Frees what upload made.
@(private)
unload :: proc(self: ^Model, r: ^render.Renderer) {
  for look in self.meshes {
    for a in look do render.destroy(r, a.mesh)
    delete(look)
  }
  for h in self.materials do render.destroy(r, h)
  for h in self.lights do render.destroy(r, h)
  for h in self.textures do render.destroy(r, h)
  delete(self.meshes)
  delete(self.materials)
  delete(self.lights)
  delete(self.textures)
}

// A rig from skin `skin` of file: its joints as the skeleton, at rest as the file poses them,
// and every clip of the file over those joints (channel i animates bone i).
@(private)
rig_from :: proc(file: ^asset.Model, skin: int) -> (rig: animation.Rig, ok: bool) {
  s := &file.skins[skin]
  names := make([]string, len(s.joints), context.temp_allocator)
  for j, i in s.joints do names[i] = file.nodes[j].name
  animation.skeleton_init(&rig.skeleton, s.parents, s.inverse_bind, names, s.rest) or_return
  for c in file.clips {
    clip: animation.Clip
    animation.clip_init(&clip, len(s.joints), c.name)
    for ch in c.channels {
      bone := slice.linear_search(s.joints, ch.node) or_continue
      interpolation := animation.Interpolation(ch.interpolation)
      switch ch.path {
      case .TRANSLATION:
        animation.clip_set_positions(&clip, bone, ch.times, slice.reinterpret([][3]f32, ch.values), interpolation)
      case .ROTATION:
        animation.clip_set_rotations(&clip, bone, ch.times, slice.reinterpret([]quaternion128, ch.values), interpolation)
      case .SCALE:
        animation.clip_set_scales(&clip, bone, ch.times, slice.reinterpret([][3]f32, ch.values), interpolation)
      }
    }
    append(&rig.clips, clip)
  }
  return rig, true
}
