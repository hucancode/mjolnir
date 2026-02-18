package ui

import cont "../containers"
import "../gpu"
import cmd "../gpu/ui"
import "core:log"
import "core:slice"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

System :: struct {
  widget_pool:      cont.Pool(Widget),
  default_texture:  gpu.Texture2DHandle,
  font_context:     ^fs.FontContext,
  font_atlas:       gpu.Texture2DHandle,
  font_atlas_dirty: bool,
  staging:          [dynamic]cmd.RenderCommand,
}

init :: proc(self: ^System, max_widgets: u32 = 4096) {
  cont.init(&self.widget_pool, max_widgets)
  self.staging = make([dynamic]cmd.RenderCommand, 0, 256)

  // Initialize fontstash (UI system owns this)
  font_atlas_width := 512
  font_atlas_height := 512
  self.font_context = new(fs.FontContext)
  fs.Init(self.font_context, font_atlas_width, font_atlas_height, .TOPLEFT)

  log.info("UI system initialized with fontstash")
}

// Initialize GPU resources (called after GPU context is ready)
init_gpu_resources :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  // Create white texture for UI widgets (1x1 white pixel)
  white_pixel := [4]u8{255, 255, 255, 255}
  white_tex_result: vk.Result
  self.default_texture, white_tex_result = gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(white_pixel[:]),
    vk.DeviceSize(len(white_pixel)),
    vk.Extent2D{1, 1},
    .R8G8B8A8_UNORM,
    {.SAMPLED},
  )
  if white_tex_result != .SUCCESS {
    log.error("Failed to create UI default white texture")
    return
  }

  // Add default font
  default_font_path := "assets/Outfit-Regular.ttf"
  font_index := fs.AddFont(self.font_context, "default", default_font_path, 0)
  if font_index == fs.INVALID {
    log.errorf("Failed to load default font from %s", default_font_path)
    return
  }

  // Pre-rasterize common glyphs
  fs.SetFont(self.font_context, font_index)
  fs.SetColor(self.font_context, {255, 255, 255, 255})
  test_string := " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
  common_sizes := [?]f32{12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96}
  for size in common_sizes {
    fs.SetSize(self.font_context, size)
    iter := fs.TextIterInit(self.font_context, 0, 0, test_string)
    quad: fs.Quad
    for fs.TextIterNext(self.font_context, &iter, &quad) {}
  }

  // Create initial font atlas texture
  self.font_atlas_dirty = true
  update_font_atlas(self, gctx, texture_manager)

  log.info("UI system GPU resources initialized")
}

shutdown_gpu_resources :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  if self.default_texture != (gpu.Texture2DHandle{}) {
    gpu.free_texture_2d(texture_manager, gctx, self.default_texture)
    self.default_texture = {}
  }
  if self.font_atlas != (gpu.Texture2DHandle{}) {
    gpu.free_texture_2d(texture_manager, gctx, self.font_atlas)
    self.font_atlas = {}
  }
  log.info("UI system GPU resources released")
}

shutdown :: proc(self: ^System) {
  // Clean up all active widgets
  cont.destroy(self.widget_pool, cleanup_widget)
  delete(self.staging)

  if self.font_context != nil {
    fs.Destroy(self.font_context)
    free(self.font_context)
  }

  log.info("UI system shutdown")
}

// Update font atlas texture when dirty
update_font_atlas :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  if !self.font_atlas_dirty do return
  if self.font_context == nil do return

  // Force fontstash to rasterize any pending glyphs
  dirty_rect: [4]f32
  if fs.ValidateTexture(self.font_context, &dirty_rect) {
    log.debugf(
      "Fontstash texture validated, dirty rect: (%.0f,%.0f,%.0f,%.0f)",
      dirty_rect[0],
      dirty_rect[1],
      dirty_rect[2],
      dirty_rect[3],
    )
  }

  // Get atlas data from fontstash
  atlas_data := self.font_context.textureData
  width := u32(self.font_context.width)
  height := u32(self.font_context.height)
  if len(atlas_data) == 0 {
    log.warn("Font atlas data is empty, cannot create texture")
    return
  }

  log.debugf(
    "Updating font atlas: %dx%d, data size: %d bytes",
    width,
    height,
    len(atlas_data),
  )

  // Free old atlas if it exists
  if self.font_atlas != (gpu.Texture2DHandle{}) {
    gpu.free_texture_2d(texture_manager, gctx, self.font_atlas)
  }

  // Create new font atlas texture
  font_atlas_result: vk.Result
  self.font_atlas, font_atlas_result = gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(atlas_data),
    vk.DeviceSize(len(atlas_data)),
    vk.Extent2D{u32(width), u32(height)},
    .R8_UNORM,
    {.SAMPLED},
  )
  if font_atlas_result != .SUCCESS {
    return
  }
  self.font_atlas_dirty = false
}

// Get font atlas texture ID for render commands
get_font_atlas_id :: proc(self: ^System) -> u32 {
  if self.font_atlas == (gpu.Texture2DHandle{}) {
    return 0
  }
  handle := transmute(cont.Handle)self.font_atlas
  return handle.index
}

cleanup_widget :: proc(widget: ^Widget) {
  switch &w in widget {
  case Mesh2D:
    delete(w.vertices)
    delete(w.indices)
  case Quad2D:
  // No dynamic allocations
  case Text2D:
    delete(w.text)
    delete(w.glyphs)
  case Box:
    // Note: children are already destroyed by pool iteration
    delete(w.children)
  }
}

UIWidgetHandle :: distinct cont.Handle
Mesh2DHandle :: distinct UIWidgetHandle
Quad2DHandle :: distinct UIWidgetHandle
Text2DHandle :: distinct UIWidgetHandle
BoxHandle :: distinct UIWidgetHandle

WidgetType :: enum {
  Mesh2D,
  Quad2D,
  Text2D,
  Box,
}

get_widget :: proc(sys: ^System, handle: UIWidgetHandle) -> ^Widget {
  widget, ok := cont.get(sys.widget_pool, handle)
  if !ok do return nil
  return widget
}

get_mesh2d :: proc(sys: ^System, handle: Mesh2DHandle) -> ^Mesh2D {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Mesh2D:
    return &w
  }
  return nil
}

get_quad2d :: proc(sys: ^System, handle: Quad2DHandle) -> ^Quad2D {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Quad2D:
    return &w
  }
  return nil
}

get_text2d :: proc(sys: ^System, handle: Text2DHandle) -> ^Text2D {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Text2D:
    return &w
  }
  return nil
}

get_box :: proc(sys: ^System, handle: BoxHandle) -> ^Box {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Box:
    return &w
  }
  return nil
}

set_position :: proc(widget: ^Widget, position: [2]f32) {
  switch &w in widget {
  case Mesh2D:
    w.position = position
  case Quad2D:
    w.position = position
  case Text2D:
    w.position = position
  case Box:
    w.position = position
  }
}

set_z_order :: proc(widget: ^Widget, z: i32) {
  switch &w in widget {
  case Mesh2D:
    w.z_order = z
  case Quad2D:
    w.z_order = z
  case Text2D:
    w.z_order = z
  case Box:
    w.z_order = z
  }
}

set_visible :: proc(widget: ^Widget, visible: bool) {
  switch &w in widget {
  case Mesh2D:
    w.visible = visible
  case Quad2D:
    w.visible = visible
  case Text2D:
    w.visible = visible
  case Box:
    w.visible = visible
  }
}

set_event_handler :: proc(widget: ^Widget, handlers: EventHandlers) {
  switch &w in widget {
  case Mesh2D:
    w.event_handlers = handlers
  case Quad2D:
    w.event_handlers = handlers
  case Text2D:
    w.event_handlers = handlers
  case Box:
    w.event_handlers = handlers
  }
}

set_user_data :: proc(widget: ^Widget, data: rawptr) {
  switch &w in widget {
  case Mesh2D:
    w.user_data = data
  case Quad2D:
    w.user_data = data
  case Text2D:
    w.user_data = data
  case Box:
    w.user_data = data
  }
}

destroy_widget :: proc(sys: ^System, handle: UIWidgetHandle) {
  widget := get_widget(sys, handle)
  if widget == nil do return

  switch &w in widget {
  case Mesh2D:
    delete(w.vertices)
    delete(w.indices)
  case Quad2D:
  // No dynamic allocations
  case Text2D:
    delete(w.text)
    delete(w.glyphs)
  case Box:
    // Destroy children recursively
    for child in w.children {
      destroy_widget(sys, child)
    }
    delete(w.children)
  }

  cont.free(&sys.widget_pool, handle)
}

// Generate render commands from widgets (staging list pattern)
generate_render_commands :: proc(sys: ^System) {
  clear(&sys.staging)

  // Get font atlas ID
  font_atlas_id := get_font_atlas_id(sys)

  // Iterate through all widgets and generate commands
  for &entry, i in sys.widget_pool.entries {
    if !entry.active do continue

    widget := &entry.item
    if widget == nil do continue
    if !get_widget_base(widget).visible do continue

    switch &w in widget {
    case Quad2D:
      raw_handle := transmute(cont.Handle)w.texture
      command := cmd.DrawQuadCommand {
        position   = w.world_position,
        size       = w.size,
        color      = w.color,
        texture_id = raw_handle.index,
        z_order    = w.z_order,
      }
      append(&sys.staging, command)

    case Mesh2D:
      raw_handle := transmute(cont.Handle)w.texture
      command := cmd.DrawMeshCommand {
        position   = w.world_position,
        vertices   = w.vertices,
        indices    = w.indices,
        texture_id = raw_handle.index,
        z_order    = w.z_order,
      }
      append(&sys.staging, command)

    case Text2D:
      // Convert glyphs to draw commands
      glyphs := make([]cmd.DrawTextGlyph, len(w.glyphs))
      for glyph, idx in w.glyphs {
        glyphs[idx] = cmd.DrawTextGlyph {
          p0    = glyph.p0,
          p1    = glyph.p1,
          uv0   = glyph.uv0,
          uv1   = glyph.uv1,
          color = w.color,
        }
      }
      command := cmd.DrawTextCommand {
        position      = w.world_position,
        glyphs        = glyphs,
        font_atlas_id = font_atlas_id,
        z_order       = w.z_order,
      }
      append(&sys.staging, command)

    case Box:
    // Boxes don't render directly
    }
  }
}
