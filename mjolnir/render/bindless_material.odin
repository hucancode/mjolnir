package render

import cont "../containers"

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

// A material, stored as the shaders read it. A texture of 0 (NO_TEXTURE)
// leaves that texture out.
Material :: struct {
  albedo_index:             TextureHandle,
  metallic_roughness_index: TextureHandle,
  normal_index:             TextureHandle,
  emissive_index:           TextureHandle,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  _:                        u32,
  base_color_factor:        [4]f32,
  // .SPRITE: sheet size in cells and the cell shown, row-major
  frame_columns:            u32,
  frame_rows:               u32,
  frame_index:              u32,
  type:                     MaterialType,
}
#assert(size_of(Material) == 64)

// A pointer to a material in the table the next frame draws from: edit it in
// place. The pointer is valid until the next frame; edits from another
// thread than frame's happen between lock and unlock.
material :: proc(r: ^Renderer, h: MaterialHandle) -> (^Material, bool) #optional_ok {
  if !cont.slots_live(&r.material_slots, u32(h)) do return nil, false
  mark_dirty(r, .MATERIALS, int(h))
  return &write_table(r, .MATERIALS, Material)[h], true
}

// create_material creates a material; it lives until destroy_material or teardown.
create_material :: proc(
  self: ^Renderer,
  type: MaterialType = .PBR,
  albedo_handle: TextureHandle = 0,
  metallic_roughness_handle: TextureHandle = 0,
  normal_handle: TextureHandle = 0,
  emissive_handle: TextureHandle = 0,
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
) -> (
  handle: MaterialHandle,
  ok: bool,
) #optional_ok {
  guard(self)
  handle = MaterialHandle(cont.slots_alloc(&self.material_slots) or_return)
  material(self, handle)^ = {
    type                     = type,
    albedo_index             = albedo_handle,
    metallic_roughness_index = metallic_roughness_handle,
    normal_index             = normal_handle,
    emissive_index           = emissive_handle,
    metallic_value           = metallic_value,
    roughness_value          = roughness_value,
    emissive_value           = emissive_value,
    base_color_factor        = base_color_factor,
    frame_columns            = max(frame_columns, 1),
    frame_rows               = max(frame_rows, 1),
  }
  return handle, true
}

// Solid-color PBR material from metallic/roughness/emissive scalars.
material_pbr :: proc(
  self: ^Renderer,
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(
    self,
    type              = .PBR,
    base_color_factor = base_color,
    metallic_value    = metallic,
    roughness_value   = roughness,
    emissive_value    = emissive,
  )
}

// material_wireframe creates a wireframe material of the given color.
material_wireframe :: proc(
  self: ^Renderer,
  base_color: [4]f32 = {1, 1, 1, 1},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(self, type = .WIREFRAME, base_color_factor = base_color)
}

// material_transparent creates an alpha-blended material of the given color.
material_transparent :: proc(
  self: ^Renderer,
  base_color: [4]f32 = {1, 1, 1, 0.5},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(self, type = .TRANSPARENT, base_color_factor = base_color)
}

// Sprite-sheet material of `frame_columns` x `frame_rows` cells, tinted by
// `tint`. Attach it with the builtin QUAD_XY mesh; it always faces the camera.
material_sprite :: proc(
  self: ^Renderer,
  texture: TextureHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  tint: [4]f32 = {1, 1, 1, 1},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(
    self,
    type = .SPRITE,
    albedo_handle = texture,
    base_color_factor = tint,
    frame_columns = frame_columns,
    frame_rows = frame_rows,
  )
}

// Show cell `frame` (row-major, wrapped to the sheet size) of a sprite
// material. Animate by calling this as time advances.
set_sprite_frame :: proc(self: ^Renderer, handle: MaterialHandle, frame: u32) -> bool {
  guard(self)
  m := material(self, handle) or_return
  m.frame_index = frame % (m.frame_columns * m.frame_rows)
  return true
}

// destroy_material frees the material slot; false if handle is not live.
destroy_material :: proc(self: ^Renderer, handle: MaterialHandle) -> bool {
  guard(self)
  cont.slots_free(&self.material_slots, u32(handle)) or_return
  clear_entry(self, .MATERIALS, u32(handle))
  return true
}

// A builtin primitive mesh drawn with a builtin color material.
primitive :: proc(
  self: ^Renderer,
  shape: Primitive = .CUBE,
  color: Color = .WHITE,
  cast_shadow := true,
) -> MeshAttachment {
  return {
    handle = self.builtin_meshes[shape],
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
    self.builtin_materials[i] = material_pbr(self, base_color = color) or_continue
  }
}
