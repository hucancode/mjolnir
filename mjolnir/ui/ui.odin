package ui

import cont "../containers"
import cmd "../draw2d"
import "core:log"
import fs "vendor:fontstash"

System :: struct {
  widget_pool:  cont.Pool(Widget),
  font_context: ^fs.FontContext,
  staging:      [dynamic]cmd.RenderCommand,
  hovered:      Maybe(UIWidgetHandle), // widget under the cursor last tick
  prev_buttons: [MAX_MOUSE_BUTTONS]bool,
}

MAX_MOUSE_BUTTONS :: 8

DEFAULT_FONT_PATH :: "assets/Outfit-Regular.ttf"

// draw2d types that appear in this package's API.
Vertex2D :: cmd.Vertex2D
NO_TEXTURE :: cmd.NO_TEXTURE

init :: proc(
  self: ^System,
  max_widgets: u32 = 4096,
  font_path: string = DEFAULT_FONT_PATH,
) -> bool {
  cont.init(&self.widget_pool, max_widgets)
  self.staging = make([dynamic]cmd.RenderCommand, 0, 256)
  font_atlas_width := 512
  font_atlas_height := 512
  self.font_context = new(fs.FontContext)
  fs.Init(self.font_context, font_atlas_width, font_atlas_height, .TOPLEFT)
  font_index := fs.AddFont(self.font_context, "default", font_path, 0)
  if font_index == fs.INVALID {
    log.errorf("Failed to load font from %s", font_path)
    return false
  }
  // Pre-rasterize common glyphs so the first atlas upload covers typical text
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
  log.info("UI system initialized with fontstash")
  return true
}

shutdown :: proc(self: ^System) {
  cont.destroy(&self.widget_pool, cleanup_widget)
  delete(self.staging)
  if self.font_context != nil {
    fs.Destroy(self.font_context)
    free(self.font_context)
  }
  log.info("UI system shutdown")
}

// Font atlas pixels (R8, width x height). changed is true when glyphs were
// rasterized since the previous call; upload the pixels to the renderer then.
take_font_atlas :: proc(
  self: ^System,
) -> (
  pixels: []u8,
  width, height: u32,
  changed: bool,
) {
  if self.font_context == nil do return
  dirty_rect: [4]f32
  changed = fs.ValidateTexture(self.font_context, &dirty_rect)
  pixels = self.font_context.textureData
  width = u32(self.font_context.width)
  height = u32(self.font_context.height)
  return
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

// Lay out all widgets and return this frame's draw commands. The slice is
// valid until the next call; glyph data lives in the temp allocator.
build_commands :: proc(sys: ^System) -> []cmd.RenderCommand {
  compute_layout_all(sys)
  clear(&sys.staging)

  // Iterate through all widgets and generate commands
  for &entry, i in sys.widget_pool.entries {
    if !entry.active do continue

    widget := &entry.item
    if widget == nil do continue
    if !get_widget_base(widget).visible do continue

    switch &w in widget {
    case Quad2D:
      command := cmd.DrawQuadCommand {
        position   = w.world_position,
        size       = w.size,
        color      = w.color,
        texture_id = w.texture,
        z_order    = w.z_order,
      }
      append(&sys.staging, command)

    case Mesh2D:
      command := cmd.DrawMeshCommand {
        position   = w.world_position,
        vertices   = w.vertices,
        indices    = w.indices,
        texture_id = w.texture,
        z_order    = w.z_order,
      }
      append(&sys.staging, command)

    case Text2D:
      // Convert glyphs to draw commands
      glyphs := make([]cmd.DrawTextGlyph, len(w.glyphs), context.temp_allocator)
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
        position = w.world_position,
        glyphs   = glyphs,
        z_order  = w.z_order,
      }
      append(&sys.staging, command)

    case Box:
    // Boxes don't render directly
    }
  }
  return sys.staging[:]
}
