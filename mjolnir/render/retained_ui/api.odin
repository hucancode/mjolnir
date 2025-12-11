package retained_ui

import cont "../../containers"
import resources "../../resources"

create_button :: proc(
  self: ^Manager,
  text: string,
  x, y, w, h: f32,
  callback: proc(ctx: rawptr) = nil,
  user_data: rawptr = nil,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, ButtonData, parent) or_return
  widget.position = {x, y}
  widget.size = {w, h}
  widget.data = ButtonData {
    text      = text,
    callback  = callback,
    user_data = user_data,
  }
  mark_dirty(self, handle)
  return
}

create_label :: proc(
  self: ^Manager,
  text: string,
  x, y: f32,
  parent: WidgetHandle = {},
  autosize: bool = false,
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, LabelData, parent) or_return
  widget.position = {x, y}
  widget.size = {100, 20}
  widget.fg_color = {0, 0, 0, 255} // Black text for labels (readable on light backgrounds)
  widget.data = LabelData {
    text     = text,
    autosize = autosize,
  }
  mark_dirty(self, handle)
  return
}

create_image :: proc(
  self: ^Manager,
  texture_handle: resources.Image2DHandle,
  x, y, w, h: f32,
  parent: WidgetHandle = {},
  uv: [4]f32 = {0, 0, 1, 1},
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, ImageData, parent) or_return
  widget.position = {x, y}
  widget.size = {w, h}
  widget.data = ImageData {
    texture_handle = texture_handle,
    uv             = uv,
    sprite_index   = 0,
    sprite_count   = 1,
  }
  mark_dirty(self, handle)
  return
}

create_window :: proc(
  self: ^Manager,
  title: string,
  x, y, w, h: f32,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, WindowData, parent) or_return
  widget.position = {x, y}
  widget.size = {w, h}
  widget.bg_color = {240, 240, 240, 255}
  widget.data = WindowData {
    title      = title,
    closeable  = true,
    moveable   = true,
    resizeable = true,
    minimized  = false,
  }
  mark_dirty(self, handle)
  return
}

create_textbox :: proc(
  self: ^Manager,
  placeholder: string,
  x, y, w, h: f32,
  max_length: u32 = 256,
  callback: proc(ctx: rawptr) = nil,
  user_data: rawptr = nil,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, TextBoxData, parent) or_return
  widget.position = {x, y}
  widget.size = {w, h}
  widget.bg_color = {255, 255, 255, 255}
  text := make([dynamic]u8, 0, max_length)
  defer if !ok do delete(text)
  widget.data = TextBoxData {
    text            = text,
    max_length      = max_length,
    placeholder     = placeholder,
    cursor_pos      = 0,
    selection_start = -1,
    selection_end   = -1,
    callback        = callback,
    user_data       = user_data,
  }
  mark_dirty(self, handle)
  ok = true
  return
}

create_combobox :: proc(
  self: ^Manager,
  items: []string,
  x, y, w, h: f32,
  callback: proc(ctx: rawptr, selected_index: i32) = nil,
  user_data: rawptr = nil,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, ComboBoxData, parent) or_return
  widget.position = {x, y}
  widget.size = {w, h}
  widget.data = ComboBoxData {
    items        = items,
    selected     = -1,
    hovered_item = -1,
    callback     = callback,
    user_data    = user_data,
  }
  mark_dirty(self, handle)
  return
}

create_checkbox :: proc(
  self: ^Manager,
  label: string,
  x, y: f32,
  checked: bool = false,
  callback: proc(ctx: rawptr, checked: bool) = nil,
  user_data: rawptr = nil,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, CheckBoxData, parent) or_return
  widget.position = {x, y}
  widget.size = {200, 20} // width for label, height for box
  widget.data = CheckBoxData {
    checked   = checked,
    label     = label,
    callback  = callback,
    user_data = user_data,
  }
  mark_dirty(self, handle)
  return
}

create_radiobutton :: proc(
  self: ^Manager,
  group_id: u32,
  label: string,
  x, y: f32,
  selected: bool = false,
  callback: proc(ctx: rawptr) = nil,
  user_data: rawptr = nil,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) #optional_ok {
  widget: ^Widget
  handle, widget = create_widget(self, RadioButtonData, parent) or_return
  widget.position = {x, y}
  widget.size = {200, 20} // width for label, height for circle
  widget.data = RadioButtonData {
    group_id  = group_id,
    selected  = selected,
    label     = label,
    callback  = callback,
    user_data = user_data,
  }
  mark_dirty(self, handle)
  return
}

set_button_callback :: proc(
  self: ^Manager,
  handle: WidgetHandle,
  callback: proc(ctx: rawptr),
  user_data: rawptr = nil,
) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  data, ok := &widget.data.(ButtonData)
  if !ok do return
  data.callback = callback
  data.user_data = user_data
}

set_label_text :: proc(self: ^Manager, handle: WidgetHandle, text: string) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  data, ok := &widget.data.(LabelData)
  if !ok do return
  data.text = text
  mark_dirty(self, handle)
}

set_button_text :: proc(self: ^Manager, handle: WidgetHandle, text: string) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  data, ok := &widget.data.(ButtonData)
  if !ok do return
  data.text = text
  mark_dirty(self, handle)
}

set_image_sprite :: proc(
  self: ^Manager,
  handle: WidgetHandle,
  sprite_index: u32,
  sprite_count: u32,
) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  data, ok := &widget.data.(ImageData)
  if !ok do return
  data.sprite_index = sprite_index
  data.sprite_count = sprite_count
  if sprite_count > 0 {
    sprite_width := 1.0 / f32(sprite_count)
    data.uv = {
      f32(sprite_index) * sprite_width,
      0,
      f32(sprite_index + 1) * sprite_width,
      1,
    }
  }
  mark_dirty(self, handle)
}

set_widget_colors :: proc(
  self: ^Manager,
  handle: WidgetHandle,
  bg_color: [4]u8,
  fg_color: [4]u8,
  border_color: [4]u8,
) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  widget.bg_color = bg_color
  widget.fg_color = fg_color
  widget.border_color = border_color
  mark_dirty(self, handle)
}

// ============================================================================
// Widget Manipulation
// ============================================================================

destroy_widget :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  child := widget.first_child
  for child.index != 0 {
    next_child := cont.get(self.widgets, child)
    next := next_child.next_sibling
    destroy_widget(self, child)
    child = next
  }
  if parent_widget, found := cont.get(self.widgets, widget.parent); found {
    if parent_widget.first_child == handle {
      parent_widget.first_child = widget.next_sibling
    }
    if parent_widget.last_child == handle {
      parent_widget.last_child = widget.prev_sibling
    }
  } else {
    for root_widget, i in self.root_widgets {
      if root_widget == handle {
        ordered_remove(&self.root_widgets, i)
        break
      }
    }
  }
  if prev, found := cont.get(self.widgets, widget.prev_sibling); found {
    prev.next_sibling = widget.next_sibling
  }
  if next, found := cont.get(self.widgets, widget.next_sibling); found {
    next.prev_sibling = widget.prev_sibling
  }
  cont.free(&self.widgets, handle)
}

set_position :: proc(self: ^Manager, handle: WidgetHandle, x, y: f32) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  widget.position = {x, y}
  mark_dirty(self, handle)
}

set_size :: proc(self: ^Manager, handle: WidgetHandle, w, h: f32) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  widget.size = {w, h}
  mark_dirty(self, handle)
}

set_visible :: proc(self: ^Manager, handle: WidgetHandle, visible: bool) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  widget.visible = visible
  mark_dirty(self, handle)
}
