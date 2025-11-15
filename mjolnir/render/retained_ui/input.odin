package retained_ui

import cont "../../containers"

update_input :: proc(self: ^Manager, mouse_x, mouse_y: f32, mouse_down: bool) {
  self.mouse_pos = {mouse_x, mouse_y}
  mouse_clicked := !self.mouse_down && mouse_down
  mouse_released := self.mouse_down && !mouse_down
  self.mouse_clicked = mouse_clicked
  self.mouse_released = mouse_released
  self.mouse_down = mouse_down
  for root_handle in self.root_widgets {
    update_widget_input(self, root_handle)
  }
}

input_text :: proc(self: ^Manager, text: string) {
  if self.focused_widget.index == 0 do return
  widget, found := cont.get(self.widgets, self.focused_widget)
  if !found || widget.type != .TEXT_BOX do return
  data := &widget.data.(TextBoxData)
  if !data.focused do return
  for ch in text {
    if len(data.text) >= int(data.max_length) do break
    append(&data.text, u8(ch))
  }
  data.text_as_string = string(data.text[:])
  if data.callback != nil {
    data.callback(data.user_data)
  }
  mark_dirty(self, self.focused_widget)
}

input_key :: proc(self: ^Manager, key: int, action: int) {
  if self.focused_widget.index == 0 do return
  widget, found := cont.get(self.widgets, self.focused_widget)
  if !found || widget.type != .TEXT_BOX do return
  data := &widget.data.(TextBoxData)
  if !data.focused do return
  if action != 1 && action != 2 do return
  if key == 259 {
    if len(data.text) > 0 {
      pop(&data.text)
      data.text_as_string = string(data.text[:])
      if data.callback != nil {
        data.callback(data.user_data)
      }
      mark_dirty(self, self.focused_widget)
    }
  }
}

deselect_radio_group :: proc(
  self: ^Manager,
  handle: WidgetHandle,
  group_id: u32,
  exclude_handle: WidgetHandle,
) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  if widget.type == .RADIO_BUTTON && handle != exclude_handle {
    data := &widget.data.(RadioButtonData)
    if data.group_id == group_id && data.selected {
      data.selected = false
      mark_dirty(self, handle)
    }
  }
  child := widget.first_child
  for child.index != 0 {
    deselect_radio_group(self, child, group_id, exclude_handle)
    child_widget, _ := cont.get(self.widgets, child)
    child = child_widget.next_sibling
  }
}

update_widget_input :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := cont.get(self.widgets, handle)
  if !found || !widget.visible || !widget.enabled do return
  mx, my := self.mouse_pos.x, self.mouse_pos.y
  wx, wy := widget.position.x, widget.position.y
  ww, wh := widget.size.x, widget.size.y
  hovered := mx >= wx && mx <= wx + ww && my >= wy && my <= wy + wh
  switch widget.type {
  case .BUTTON:
    data := &widget.data.(ButtonData)
    old_hovered := data.hovered
    data.hovered = hovered
    if hovered && self.mouse_clicked {
      data.pressed = true
      mark_dirty(self, handle)
    }
    if data.pressed && self.mouse_released {
      data.pressed = false
      mark_dirty(self, handle)
      if hovered && data.callback != nil {
        data.callback(data.user_data)
      }
    }
    if old_hovered != data.hovered {
      mark_dirty(self, handle)
    }
  case .CHECK_BOX:
    data := &widget.data.(CheckBoxData)
    box_size: f32 = 20
    old_hovered := data.hovered
    data.hovered = hovered && mx <= wx + box_size && my <= wy + box_size
    if data.hovered && self.mouse_clicked {
      data.checked = !data.checked
      if data.callback != nil {
        data.callback(data.user_data, data.checked)
      }
      mark_dirty(self, handle)
    }
    if old_hovered != data.hovered {
      mark_dirty(self, handle)
    }
  case .RADIO_BUTTON:
    data := &widget.data.(RadioButtonData)
    circle_size: f32 = 20
    old_hovered := data.hovered
    data.hovered = hovered && mx <= wx + circle_size && my <= wy + circle_size
    if data.hovered && self.mouse_clicked && !data.selected {
      for other_handle in self.root_widgets {
        deselect_radio_group(self, other_handle, data.group_id, handle)
      }
      data.selected = true
      if data.callback != nil {
        data.callback(data.user_data)
      }
      mark_dirty(self, handle)
    }
    if old_hovered != data.hovered {
      mark_dirty(self, handle)
    }
  case .TEXT_BOX:
    data := &widget.data.(TextBoxData)
    old_hovered := data.hovered
    old_focused := data.focused
    data.hovered = hovered
    if self.mouse_clicked {
      if self.focused_widget.index != 0 && self.focused_widget != handle {
        if old_focused_widget, ok := cont.get(
          self.widgets,
          self.focused_widget,
        ); ok {
          if old_data, is_textbox := &old_focused_widget.data.(TextBoxData);
             is_textbox {
            old_data.focused = false
            mark_dirty(self, self.focused_widget)
          }
        }
      }
      data.focused = hovered
      if hovered {
        self.focused_widget = handle
      } else if self.focused_widget == handle {
        self.focused_widget = {}
      }
    }
    if old_hovered != data.hovered || old_focused != data.focused {
      mark_dirty(self, handle)
    }
  case .COMBO_BOX:
    data := &widget.data.(ComboBoxData)
    old_hovered := data.hovered
    old_expanded := data.expanded
    data.hovered = hovered && my <= wy + widget.size.y
    if data.hovered && self.mouse_clicked {
      data.expanded = !data.expanded
      mark_dirty(self, handle)
    }
    if data.expanded {
      item_height: f32 = 24
      dropdown_y := wy + widget.size.y
      old_hovered_item := data.hovered_item
      data.hovered_item = -1
      for item, i in data.items {
        item_y := dropdown_y + f32(i) * item_height
        if mx >= wx &&
           mx <= wx + ww &&
           my >= item_y &&
           my <= item_y + item_height {
          data.hovered_item = i32(i)
          if self.mouse_clicked {
            selected_index := i32(i)
            callback := data.callback
            user_data := data.user_data
            data.selected = selected_index
            data.expanded = false
            mark_dirty(self, handle)
            if callback != nil {
              callback(user_data, selected_index)
            }
            widget, found = cont.get(self.widgets, handle)
            if !found do return
            data = &widget.data.(ComboBoxData)
            break
          }
        }
      }
      if old_hovered_item != data.hovered_item {
        mark_dirty(self, handle)
      }
    }
    if old_hovered != data.hovered || old_expanded != data.expanded {
      mark_dirty(self, handle)
    }
  case .LABEL, .IMAGE, .WINDOW:
  }
  child := widget.first_child
  for child.index != 0 {
    update_widget_input(self, child)
    child_widget, _ := cont.get(self.widgets, child)
    child = child_widget.next_sibling
  }
}
