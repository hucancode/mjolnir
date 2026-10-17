package render

import "../containers"

// bit t set for every G-buffer type t; views mask material types in a u32
#assert(len(MaterialType) <= 32)
@(private)
GBUFFER_TYPES :: u32(1) << u32(FIRST_FORWARD_TYPE) - 1

// Color names a builtin solid-color material in Renderer.builtin_materials.
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
}

// Material is how a mesh surface looks. A texture of 0 (NO_TEXTURE) leaves that texture out;
// type picks which fields matter (see make_material).
Material :: struct {
  albedo_texture:             TextureHandle,
  metallic_roughness_texture: TextureHandle,
  normal_texture:             TextureHandle,
  emissive_texture:           TextureHandle,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  // .CUSTOM: the user shader drawing it
  shader:                   MaterialShader,
  base_color_factor:        [4]f32,
  // .SPRITE: sheet size in cells and the cell shown, row-major
  frame_columns:            u32,
  frame_rows:               u32,
  frame_index:              u32,
  type:                     MaterialType,
  // .CUSTOM: the shader's own values, read as m.params[i] (built-in types ignore them)
  params:                   [2][4]f32,
}
#assert(size_of(Material) == 96)

// material returns the material of `handle`, to edit in place; the pointer is valid until the
// next frame. Edits from another thread than frame's happen between lock and unlock.
material :: proc(self: ^Renderer, handle: MaterialHandle) -> (^Material, bool) #optional_ok {
  if !containers.slots_live(&self.material_slots, u32(handle)) do return nil, false
  mark_dirty(self, .MATERIALS, int(handle))
  return &write_table(self, .MATERIALS, Material)[handle], true
}

// make_material returns a Material for material_create. type picks how it draws: .SPRITE
// shows a frame_columns x frame_rows sheet cell of albedo_texture on a camera-facing QUAD_XY;
// .CUSTOM is drawn by shader (material_shader_create), which reads params (its own values)
// and any other field.
make_material :: proc(
  type: MaterialType = .PBR,
  albedo_texture: TextureHandle = NO_TEXTURE,
  metallic_roughness_texture: TextureHandle = NO_TEXTURE,
  normal_texture: TextureHandle = NO_TEXTURE,
  emissive_texture: TextureHandle = NO_TEXTURE,
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  shader: MaterialShader = 0,
  params: [2][4]f32 = {},
) -> Material {
  return {
    type                       = type,
    albedo_texture             = albedo_texture,
    metallic_roughness_texture = metallic_roughness_texture,
    normal_texture             = normal_texture,
    emissive_texture           = emissive_texture,
    metallic_value             = metallic_value,
    roughness_value            = roughness_value,
    emissive_value             = emissive_value,
    base_color_factor          = base_color_factor,
    frame_columns              = frame_columns,
    frame_rows                 = frame_rows,
    shader                     = shader,
    params                     = params,
  }
}

// material_create stores `m` (make_material fills one); it lives until material_destroy or
// teardown. A sprite sheet of 0 columns or rows counts as 1.
material_create :: proc(self: ^Renderer, m: Material) -> (handle: MaterialHandle, ok: bool) #optional_ok {
  guard(self)
  handle = MaterialHandle(containers.slots_alloc(&self.material_slots) or_return)
  material(self, handle)^ = m
  material(self, handle).frame_columns = max(m.frame_columns, 1)
  material(self, handle).frame_rows = max(m.frame_rows, 1)
  return handle, true
}

// set_sprite_frame shows cell `frame` (row-major, wrapped to the sheet size) of a sprite
// material. Animate by calling it as time advances.
set_sprite_frame :: proc(self: ^Renderer, handle: MaterialHandle, frame: u32) -> bool {
  guard(self)
  m := material(self, handle) or_return
  m.frame_index = frame % (m.frame_columns * m.frame_rows)
  return true
}

// material_destroy frees the material; a stale handle is ignored.
material_destroy :: proc(self: ^Renderer, handle: MaterialHandle) {
  guard(self)
  if containers.slots_free(&self.material_slots, u32(handle)) do clear_entry(self, .MATERIALS, u32(handle))
}

// primitive returns a builtin mesh (builtin_meshes) drawn with a builtin color material
// (builtin_materials), ready to attach.
primitive :: proc(
  self: ^Renderer,
  shape: Primitive = .CUBE,
  color: Color = .WHITE,
  cast_shadow := true,
) -> MeshAttachment {
  return {
    mesh = self.builtin_meshes[shape],
    material = self.builtin_materials[color],
    cast_shadow = cast_shadow,
  }
}

@(private)
init_builtin_materials :: proc(self: ^Renderer) {
  colors := [Color][4]f32 {
    .WHITE = {1.0, 1.0, 1.0, 1.0},
    .BLACK = {0.0, 0.0, 0.0, 1.0},
    .GRAY = {0.3, 0.3, 0.3, 1.0},
    .RED = {1.0, 0.0, 0.0, 1.0},
    .GREEN = {0.0, 1.0, 0.0, 1.0},
    .BLUE = {0.0, 0.0, 1.0, 1.0},
    .YELLOW = {1.0, 1.0, 0.0, 1.0},
    .CYAN = {0.0, 1.0, 1.0, 1.0},
    .MAGENTA = {1.0, 0.0, 1.0, 1.0},
  }
  for color, i in colors {
    self.builtin_materials[i] = material_create(self, make_material(base_color_factor = color)) or_continue
  }
}
