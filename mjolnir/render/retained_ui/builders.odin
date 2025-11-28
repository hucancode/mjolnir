package retained_ui

import cont "../../containers"
import fs "vendor:fontstash"
import "core:log"

build_widget_draw_commands :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := cont.get(self.widgets, handle)
  if !found || !widget.visible do return
  for &v in self.draw_lists {
    switch data in widget.data {
    case ButtonData:
      build_button_commands(self, &v, handle, widget)
    case LabelData:
      build_label_commands(self, &v, handle, widget)
    case ImageData:
      build_image_commands(self, &v, handle, widget)
    case WindowData:
      build_window_commands(self, &v, handle, widget)
    case TextBoxData:
      build_textbox_commands(self, &v, handle, widget)
    case ComboBoxData:
      build_combobox_commands(self, &v, handle, widget)
    case CheckBoxData:
      build_checkbox_commands(self, &v, handle, widget)
    case RadioButtonData:
      build_radiobutton_commands(self, &v, handle, widget)
    }
  }
  // re-fetch widget pointer in case pool was modified
  if widget, found = cont.get(self.widgets, handle); found {
    widget.dirty = false
  }
}

build_widget_tree_commands :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := cont.get(self.widgets, handle)
  if !found || !widget.visible do return
  build_widget_draw_commands(self, handle)
  child := widget.first_child
  for child.index != 0 {
    build_widget_tree_commands(self, child)
    child_widget := cont.get(self.widgets, child)
    child = child_widget.next_sibling
  }
}

build_button_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(ButtonData)
  bg_color := widget.bg_color
  if data.pressed {
    bg_color = {
      u8(widget.bg_color.r / 2),
      u8(widget.bg_color.g / 2),
      u8(widget.bg_color.b / 2),
      widget.bg_color.a,
    }
  } else if data.hovered {
    bg_color = {
      max(widget.bg_color.r - 40, 0),
      max(widget.bg_color.g - 40, 0),
      max(widget.bg_color.b - 40, 0),
      widget.bg_color.a,
    }
  }
  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {
        widget.position.x,
        widget.position.y,
        widget.size.x,
        widget.size.y,
      },
      color = bg_color,
      uv = {0, 0, 1, 1},
    },
  )
  append(
    &draw_list.commands,
    DrawCommand {
      type = .TEXT,
      widget = handle,
      rect = {
        widget.position.x + 10,
        widget.position.y + 10,
        widget.size.x - 20,
        widget.size.y - 20,
      },
      color = widget.fg_color,
      text = data.text,
      text_align = .CENTER,
    },
  )
}

build_label_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(LabelData)

  if data.autosize && len(data.text) > 0 {
    font_size := widget.size.y
    fs.SetFont(&self.font_ctx, self.default_font)
    fs.SetSize(&self.font_ctx, font_size)
    bounds: [4]f32
    fs.TextBounds(&self.font_ctx, data.text, 0, 0, &bounds)
    text_width := bounds[2] - bounds[0]
    widget.size.x = text_width + 4
  }

  append(
    &draw_list.commands,
    DrawCommand {
      type = .TEXT,
      widget = handle,
      rect = {
        widget.position.x,
        widget.position.y,
        widget.size.x,
        widget.size.y,
      },
      color = widget.fg_color,
      text = data.text,
      text_align = .LEFT,
    },
  )
}

build_image_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(ImageData)
  append(
    &draw_list.commands,
    DrawCommand {
      type = .IMAGE,
      widget = handle,
      rect = {
        widget.position.x,
        widget.position.y,
        widget.size.x,
        widget.size.y,
      },
      color = WHITE,
      texture_id = data.texture_handle.index,
      uv = data.uv,
      z = 0.0,
    },
  )
}

build_window_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(WindowData)
  title_bar_height: f32 = 30
  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {
        widget.position.x,
        widget.position.y,
        widget.size.x,
        title_bar_height,
      },
      color = BUTTON_SHADOW_COLOR,
      uv = {0, 0, 1, 1},
    },
  )
  append(
    &draw_list.commands,
    DrawCommand {
      type = .TEXT,
      widget = handle,
      rect = {
        widget.position.x + 10,
        widget.position.y + 5,
        widget.size.x - 20,
        title_bar_height - 10,
      },
      color = WHITE,
      text = data.title,
      text_align = .LEFT,
    },
  )
  if !data.minimized {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .RECT,
        widget = handle,
        rect = {
          widget.position.x,
          widget.position.y + title_bar_height,
          widget.size.x,
          widget.size.y - title_bar_height,
        },
        color = widget.bg_color,
        uv = {0, 0, 1, 1},
      },
    )
  }
}

build_textbox_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(TextBoxData)
  bg_color := widget.bg_color
  if data.focused {
    bg_color = WHITE
  } else if data.hovered {
    bg_color = TEXTBOX_BG_HOVERED
  }
  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {
        widget.position.x,
        widget.position.y,
        widget.size.x,
        widget.size.y,
      },
      color = bg_color,
      uv = {0, 0, 1, 1},
    },
  )
  border_color := data.focused ? TEXTBOX_BORDER_FOCUSED : widget.border_color
  if len(data.text) == 0 {
    if len(data.placeholder) > 0 {
      append(
        &draw_list.commands,
        DrawCommand {
          type = .TEXT,
          widget = handle,
          rect = {
            widget.position.x + 8,
            widget.position.y + 8,
            widget.size.x - 16,
            widget.size.y - 16,
          },
          color = TEXTBOX_PLACEHOLDER_COLOR,
          text = data.placeholder,
          text_align = .LEFT,
        },
      )
    }
  } else {
    append(
      &draw_list.commands,
      DrawCommand {
        type        = .TEXT,
        widget      = handle,
        rect        = {
          widget.position.x + 8,
          widget.position.y + 8,
          widget.size.x - 16,
          widget.size.y - 16,
        },
        color       = widget.fg_color,
        text        = data.text_as_string,
        text_align  = .LEFT,
        text_suffix = true,
      },
    )
  }
  if data.focused {
    text_width: f32 = 0
    available_width := widget.size.x - 16
    text_offset: f32 = 0
    if len(data.text) > 0 {
      font_size := widget.size.y - 16
      fs.SetFont(&self.font_ctx, self.default_font)
      fs.SetSize(&self.font_ctx, font_size)
      bounds: [4]f32
      fs.TextBounds(&self.font_ctx, data.text_as_string, 0, 0, &bounds)
      text_width = bounds[2] - bounds[0]
      if text_width > available_width {
        text_offset = available_width - text_width
      }
    }
    cursor_x := widget.position.x + 8 + text_offset + text_width
    if cursor_x > widget.position.x + 8 + available_width {
      cursor_x = widget.position.x + 8 + available_width
    }
    cursor_y := widget.position.y + 6
    cursor_height := widget.size.y - 12
    append(
      &draw_list.commands,
      DrawCommand {
        type   = .RECT,
        widget = handle,
        rect   = {cursor_x, cursor_y, 2, cursor_height},
        color  = {0, 0, 0, 255},
        uv     = {0, 0, 1, 1},
      },
    )
  }
}

build_combobox_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(ComboBoxData)
  bg_color := data.hovered ? DROPDOWN_HOVER_BG : widget.bg_color
  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {
        widget.position.x,
        widget.position.y,
        widget.size.x,
        widget.size.y,
      },
      color = bg_color,
      uv = {0, 0, 1, 1},
    },
  )
  if data.selected >= 0 && data.selected < i32(len(data.items)) {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .TEXT,
        widget = handle,
        rect = {
          widget.position.x + 8,
          widget.position.y + 8,
          widget.size.x - 32,
          widget.size.y - 16,
        },
        color = widget.fg_color,
        text = data.items[data.selected],
        text_align = .LEFT,
      },
    )
  } else {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .TEXT,
        widget = handle,
        rect = {
          widget.position.x + 8,
          widget.position.y + 8,
          widget.size.x - 32,
          widget.size.y - 16,
        },
        color = widget.fg_color,
        text = "Select...",
        text_align = .LEFT,
      },
    )
  }
  cue_width: f32 = 8
  cue_color := data.expanded ? DROPDOWN_OPEN_HINT_BG : DROPDOWN_CLOSE_HINT_BG
  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {
        widget.position.x + widget.size.x - cue_width,
        widget.position.y,
        cue_width,
        widget.size.y,
      },
      color = cue_color,
      uv = {0, 0, 1, 1},
    },
  )
  if data.expanded {
    item_height: f32 = 24
    dropdown_y := widget.position.y + widget.size.y
    for item, i in data.items {
      item_bg :=
        data.hovered_item == i32(i) ? DROPDOWN_LIST_HOVER_BG : DROPDOWN_LIST_BG
      append(
        &draw_list.commands,
        DrawCommand {
          type = .RECT,
          widget = handle,
          rect = {
            widget.position.x,
            dropdown_y + f32(i) * item_height,
            widget.size.x,
            item_height,
          },
          color = item_bg,
          uv = {0, 0, 1, 1},
          z = -0.01,
        },
      )
      append(
        &draw_list.commands,
        DrawCommand {
          type = .TEXT,
          widget = handle,
          rect = {
            widget.position.x + 8,
            dropdown_y + f32(i) * item_height + 4,
            widget.size.x - 16,
            item_height - 8,
          },
          color = BLACK,
          text = item,
          text_align = .LEFT,
          z = -0.01,
        },
      )
    }
  }
}

build_checkbox_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(CheckBoxData)
  box_size: f32 = 20
  spacing: f32 = 8
  box_bg := data.hovered ? CHECKBOX_HOVER_BG : widget.bg_color
  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {widget.position.x, widget.position.y, box_size, box_size},
      color = box_bg,
      uv = {0, 0, 1, 1},
    },
  )
  if data.checked {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .RECT,
        widget = handle,
        rect = {
          widget.position.x + 2,
          widget.position.y + 2,
          box_size - 4,
          box_size - 4,
        },
        color = BLACK,
        uv = {0, 0, 1, 1},
      },
    )
  }
  if len(data.label) > 0 {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .TEXT,
        widget = handle,
        rect = {
          widget.position.x + box_size + spacing,
          widget.position.y,
          widget.size.x - box_size - spacing,
          box_size,
        },
        color = widget.fg_color,
        text = data.label,
        text_align = .LEFT,
      },
    )
  }
}

build_radiobutton_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(RadioButtonData)
  circle_size: f32 = 20
  spacing: f32 = 8
  circle_bg := data.hovered ? RADIO_BUTTON_HOVER_BG : widget.bg_color
  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {widget.position.x, widget.position.y, circle_size, circle_size},
      color = circle_bg,
      uv = {0, 0, 1, 1},
    },
  )
  if data.selected {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .RECT,
        widget = handle,
        rect = {
          widget.position.x + 4,
          widget.position.y + 4,
          circle_size - 8,
          circle_size - 8,
        },
        color = BLACK,
        uv = {0, 0, 1, 1},
      },
    )
  }
  if len(data.label) > 0 {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .TEXT,
        widget = handle,
        rect = {
          widget.position.x + circle_size + spacing,
          widget.position.y,
          widget.size.x - circle_size - spacing,
          circle_size,
        },
        color = widget.fg_color,
        text = data.label,
        text_align = .LEFT,
      },
    )
  }
}
