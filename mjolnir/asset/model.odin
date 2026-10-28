package asset

import "../geometry"

// Model is a model file's content, every index into its own arrays (-1 for none).
Model :: struct {
  // per mesh, its primitives
  meshes:    [][]Primitive,
  materials: []Material,
  // encoded image files (png, jpg) the materials sample
  images:    [][]u8,
  // parents before children
  nodes:     []Node,
  skins:     []Skin,
  clips:     []Clip,
  lights:    []Light,
}

// Primitive is one part of a mesh drawn with one material. Its mesh carries skinning data when
// a skinned node uses it.
Primitive :: struct {
  mesh:     geometry.Mesh,
  material: int,
}

// TextureSlot names a material's textures; the color ones (ALBEDO, EMISSIVE) hold sRGB data.
TextureSlot :: enum {
  ALBEDO,
  METALLIC_ROUGHNESS,
  NORMAL,
  EMISSIVE,
}

// Material is a metallic-roughness surface: factors, and the image of each texture slot.
Material :: struct {
  base_color: [4]f32,
  metallic:   f32,
  roughness:  f32,
  // emissive strength, the brightest channel of the emissive factor
  emissive:   f32,
  textures:   [TextureSlot]int,
}

// Node is one node of the tree: its local transform, and what it holds.
Node :: struct {
  name:      string,
  parent:    int,
  transform: geometry.Transform,
  mesh:      int,
  // the skin deforming its mesh
  skin:      int,
  light:     int,
}

// Skin is a joint hierarchy: joint i is node joints[i], under joint parents[i]; rest is each
// joint's local transform as the file poses it.
Skin :: struct {
  name:         string,
  joints:       []int,
  parents:      []i32,
  inverse_bind: []matrix[4, 4]f32,
  rest:         []geometry.Transform,
}

// Clip is one animation: channels moving nodes over time.
Clip :: struct {
  name:     string,
  channels: []Channel,
}

// Path is what a channel animates.
Path :: enum {
  TRANSLATION,
  ROTATION,
  SCALE,
}

// Interpolation is how a channel moves between keys; CUBIC keys hold 3 values (in-tangent,
// value, out-tangent).
Interpolation :: enum {
  LINEAR,
  STEP,
  CUBIC,
}

// Channel animates one node's path: values holds 3 floats per key (4 for ROTATION), times one.
Channel :: struct {
  node:          int,
  path:          Path,
  interpolation: Interpolation,
  times:         []f32,
  values:        []f32,
}

// LightType is how a Light shines.
LightType :: enum {
  DIRECTIONAL,
  POINT,
  SPOT,
}

// Light is a punctual light, in the file's units (lux, candela); range 0 is unbounded.
Light :: struct {
  type:        LightType,
  color:       [3]f32,
  intensity:   f32,
  range:       f32,
  inner_angle: f32,
  outer_angle: f32,
}

// model_destroy frees everything the model holds.
model_destroy :: proc(self: ^Model) {
  for prims in self.meshes {
    for p in prims do geometry.mesh_destroy(p.mesh)
    delete(prims)
  }
  for img in self.images do delete(img)
  for n in self.nodes do delete(n.name)
  for s in self.skins {
    delete(s.name)
    delete(s.joints)
    delete(s.parents)
    delete(s.inverse_bind)
    delete(s.rest)
  }
  for c in self.clips {
    delete(c.name)
    for ch in c.channels {
      delete(ch.times)
      delete(ch.values)
    }
    delete(c.channels)
  }
  delete(self.meshes)
  delete(self.materials)
  delete(self.images)
  delete(self.nodes)
  delete(self.skins)
  delete(self.clips)
  delete(self.lights)
  self^ = {}
}

// destroy frees a Model, as model_destroy does.
destroy :: proc {
  model_destroy,
}
