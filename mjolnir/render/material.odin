package render


// bit t set for every G-buffer type t; views mask material types in a u32
#assert(DRAW_LISTS <= 32)
@(private)
GBUFFER_TYPES :: u32(1) << u32(FIRST_FORWARD_TYPE) - 1

// Color names a builtin solid-color material (primitive), colored COLOR_RGB.
Color :: enum {
  WHITE,
  BLACK,
  GRAY,
  RED,
  GREEN,
  BLUE,
  YELLOW,
  CYAN,
  MAGENTA,
  ORANGE,
}

// Material is how a mesh surface looks. A texture of 0 (NO_TEXTURE) leaves that texture out;
// type picks which fields matter (see make_material).
Material :: struct {
  albedo_texture:             TextureHandle,
  metallic_roughness_texture: TextureHandle,
  normal_texture:             TextureHandle,
  emissive_texture:           TextureHandle,
  metallic_factor:            f32,
  roughness_factor:           f32,
  emissive_factor:            f32,
  type:                       MaterialType,
  base_color_factor:          [4]f32,
  // .SPRITE: the frames its sprites pick from (MeshAttachment.frame, sprite_frame); none shows
  // the whole albedo texture
  sprite_frames:              SpriteFramesHandle,
  _:                          [3]u32,
  // your shader's own values (material_shader_create), read as m.params[i]; the built-in types
  // ignore them
  params:                     [4][4]f32,
}
#assert(size_of(Material) == 128)

// material returns the material of `handle`, to edit in place; the pointer is valid for
// this tick: getting it marks the data for upload, so get it again next tick.
material :: proc(self: ^Renderer, handle: MaterialHandle) -> (^Material, bool) #optional_ok {
  return resource(self, .MATERIALS, Material, u32(handle))
}

// make_material returns a Material for material_create. type picks how it draws: .SPRITE
// draws a camera-facing QUAD_XY as one frame of sprite_frames in albedo_texture (each node its
// own frame, MeshAttachment.frame; the frame's size times the node's x and y scale is its size,
// a negative scale mirrors it; MeshAttachment.turned lays it in the node's XY plane instead; pixels under half alpha are cut out and the nearer sprite covers
// the farther); a type from material_shader_create is drawn by that shader, which reads params
// (its own values) and any other field.
make_material :: proc(
  type: MaterialType = .PBR,
  albedo_texture: TextureHandle = NO_TEXTURE,
  metallic_roughness_texture: TextureHandle = NO_TEXTURE,
  normal_texture: TextureHandle = NO_TEXTURE,
  emissive_texture: TextureHandle = NO_TEXTURE,
  metallic_factor: f32 = 0.0,
  roughness_factor: f32 = 1.0,
  emissive_factor: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  sprite_frames: SpriteFramesHandle = 0,
  params: [4][4]f32 = {},
) -> Material {
  return {
    type                       = type,
    albedo_texture             = albedo_texture,
    metallic_roughness_texture = metallic_roughness_texture,
    normal_texture             = normal_texture,
    emissive_texture           = emissive_texture,
    metallic_factor            = metallic_factor,
    roughness_factor           = roughness_factor,
    emissive_factor            = emissive_factor,
    base_color_factor          = base_color_factor,
    sprite_frames              = sprite_frames,
    params                     = params,
  }
}

// material_create stores `m` (make_material fills one); it lives until material_destroy or
// teardown.
material_create :: proc(self: ^Renderer, m: Material) -> (handle: MaterialHandle, ok: bool) #optional_ok {
  return MaterialHandle(resource_create(self, .MATERIALS, m) or_return), true
}

// material_destroy frees the material; destroy each handle once.
material_destroy :: proc(self: ^Renderer, handle: MaterialHandle) {
  resource_destroy(self, .MATERIALS, u32(handle))
}

// primitive returns a builtin mesh ready to attach, drawn with either
//   a builtin color material:
//     primitive(r, shape = .CUBE, color = .WHITE, no_shadow = false) -> MeshAttachment
//   a material of yours:
//     primitive(r, shape, material: MaterialHandle, no_shadow = false) -> MeshAttachment
primitive :: proc {
  primitive_color,
  primitive_material,
}

@(private = "file")
primitive_color :: proc(
  self: ^Renderer,
  shape: Primitive = .CUBE,
  color: Color = .WHITE,
  no_shadow := false,
) -> MeshAttachment {
  return primitive_material(self, shape, self.builtin_materials[color], no_shadow)
}

@(private = "file")
primitive_material :: proc(
  self: ^Renderer,
  shape: Primitive,
  material: MaterialHandle,
  no_shadow := false,
) -> MeshAttachment {
  return {mesh = self.builtin_meshes[shape], material = material, no_shadow = no_shadow}
}

// COLOR_RGB is the base color of each builtin color material (Color).
COLOR_RGB :: [Color][4]f32 {
  .WHITE   = {1.0, 1.0, 1.0, 1.0},
  .BLACK   = {0.0, 0.0, 0.0, 1.0},
  .GRAY    = {0.3, 0.3, 0.3, 1.0},
  .RED     = {1.0, 0.0, 0.0, 1.0},
  .GREEN   = {0.0, 1.0, 0.0, 1.0},
  .BLUE    = {0.0, 0.0, 1.0, 1.0},
  .YELLOW  = {1.0, 1.0, 0.0, 1.0},
  .CYAN    = {0.0, 1.0, 1.0, 1.0},
  .MAGENTA = {1.0, 0.0, 1.0, 1.0},
  .ORANGE  = {1.0, 0.5, 0.0, 1.0},
}

@(private)
init_builtin_materials :: proc(self: ^Renderer) {
  for color, i in COLOR_RGB {
    self.builtin_materials[i] = material_create(self, make_material(base_color_factor = color)) or_continue
  }
}
