package retained_ui

import cont "../../containers"
import resources "../../resources"
import "core:fmt"

// =============================================================================
// Widget Structures
// =============================================================================

// Button = FlexBox (container) + Quad2D (background) + Text2D (label)
ButtonWidget :: struct {
  root:       FlexBoxHandle,
  background: ElementHandle,
  label:      ElementHandle,
  callback:   proc(ctx: rawptr),
  user_data:  rawptr,
  // State
  hovered:    bool,
  pressed:    bool,
  // Colors
  normal_bg:  [4]u8,
  hover_bg:   [4]u8,
  press_bg:   [4]u8,
}

// Label = Text2D (simple wrapper)
LabelWidget :: struct {
  text_element: ElementHandle,
}

// TextInput = FlexBox + Quad2D (bg) + Text2D (content) + Quad2D (cursor)
TextInputWidget :: struct {
  root:             FlexBoxHandle,
  background:       ElementHandle,
  text:             ElementHandle,
  cursor:           ElementHandle,
  placeholder:      ElementHandle,
  // State
  focused:          bool,
  hovered:          bool,
  cursor_pos:       u32,
  buffer:           [dynamic]u8,
  buffer_str:       string, // View into buffer
  placeholder_text: string,
  callback:         proc(ctx: rawptr, text: string),
  user_data:        rawptr,
}

// Dropdown = FlexBox + Quad (selected display) + Text (selected text) + FlexBox (list) + items
DropdownWidget :: struct {
  root:          FlexBoxHandle,
  selected_bg:   ElementHandle,
  selected_text: ElementHandle,
  dropdown_list: FlexBoxHandle,
  item_bgs:      [dynamic]ElementHandle,
  item_texts:    [dynamic]ElementHandle,
  // State
  expanded:      bool,
  hovered:       bool,
  hovered_item:  i32,
  selected_idx:  i32,
  items:         []string,
  callback:      proc(ctx: rawptr, index: i32),
  user_data:     rawptr,
}

// Checkbox = FlexBox + Quad2D (box) + Quad2D (checkmark) + Text2D (label)
CheckboxWidget :: struct {
  root:      FlexBoxHandle,
  box:       ElementHandle,
  checkmark: ElementHandle,
  label:     ElementHandle,
  // State
  checked:   bool,
  hovered:   bool,
  callback:  proc(ctx: rawptr, checked: bool),
  user_data: rawptr,
}

// =============================================================================
// Button Widget
// =============================================================================

create_button :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  text: string,
  callback: proc(ctx: rawptr) = nil,
  user_data: rawptr = nil,
  width: f32 = 150,
  height: f32 = 40,
) -> (
  widget: ButtonWidget,
  ok: bool,
) #optional_ok {
  // Create container
  widget.root = create_flexbox(manager, parent) or_return
  set_flexbox_size(manager, widget.root, SizeAbsolute{width, height})
  set_flexbox_direction(manager, widget.root, .ROW)
  set_flexbox_justify(manager, widget.root, .CENTER)
  set_flexbox_align(manager, widget.root, .CENTER)

  // Create background
  widget.background = create_quad(
    manager,
    widget.root,
    BUTTON_DEFAULT_BG,
    SizeRelativeParent{1.0, 1.0},
  ) or_return
  set_z_order(manager, widget.background, -0.1)

  // Create label
  widget.label = create_text(manager, widget.root, text, 16, WHITE) or_return

  // Store state
  widget.callback = callback
  widget.user_data = user_data
  widget.normal_bg = BUTTON_DEFAULT_BG
  widget.hover_bg = BUTTON_HOVER_BG
  widget.press_bg = BUTTON_PRESS_BG

  // Register event handlers
  on_event(
    manager,
    widget.background,
    .MOUSE_ENTER,
    button_hover_enter,
    &widget,
  )
  on_event(
    manager,
    widget.background,
    .MOUSE_LEAVE,
    button_hover_leave,
    &widget,
  )
  on_event(manager, widget.background, .MOUSE_DOWN, button_mouse_down, &widget)
  on_event(manager, widget.background, .MOUSE_UP, button_mouse_up, &widget)
  on_click(manager, widget.background, button_click_handler, &widget)

  return widget, true
}

@(private)
button_hover_enter :: proc(event: ^Event, user_data: rawptr) {
  btn := cast(^ButtonWidget)user_data
  btn.hovered = true
  // Update color - would need manager access to change color
}

@(private)
button_hover_leave :: proc(event: ^Event, user_data: rawptr) {
  btn := cast(^ButtonWidget)user_data
  btn.hovered = false
  btn.pressed = false
}

@(private)
button_mouse_down :: proc(event: ^Event, user_data: rawptr) {
  btn := cast(^ButtonWidget)user_data
  btn.pressed = true
}

@(private)
button_mouse_up :: proc(event: ^Event, user_data: rawptr) {
  btn := cast(^ButtonWidget)user_data
  btn.pressed = false
}

@(private)
button_click_handler :: proc(event: ^Event, user_data: rawptr) {
  btn := cast(^ButtonWidget)user_data
  if btn.callback != nil {
    btn.callback(btn.user_data)
  }
}

set_button_text :: proc(
  manager: ^Manager,
  widget: ^ButtonWidget,
  text: string,
) {
  set_text_content(manager, widget.label, text)
}

set_button_colors :: proc(
  manager: ^Manager,
  widget: ^ButtonWidget,
  normal, hover, press: [4]u8,
) {
  widget.normal_bg = normal
  widget.hover_bg = hover
  widget.press_bg = press
  // Update current color based on state
  if widget.pressed {
    set_quad_color(manager, widget.background, press)
  } else if widget.hovered {
    set_quad_color(manager, widget.background, hover)
  } else {
    set_quad_color(manager, widget.background, normal)
  }
}

update_button_appearance :: proc(manager: ^Manager, widget: ^ButtonWidget) {
  if widget.pressed {
    set_quad_color(manager, widget.background, widget.press_bg)
  } else if widget.hovered {
    set_quad_color(manager, widget.background, widget.hover_bg)
  } else {
    set_quad_color(manager, widget.background, widget.normal_bg)
  }
}

// =============================================================================
// Label Widget
// =============================================================================

create_label :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  text: string,
  font_size: f32 = 16,
  color: [4]u8 = BLACK,
) -> (
  widget: LabelWidget,
  ok: bool,
) #optional_ok {
  widget.text_element = create_text(
    manager,
    parent,
    text,
    font_size,
    color,
  ) or_return
  return widget, true
}

set_label_text :: proc(manager: ^Manager, widget: ^LabelWidget, text: string) {
  set_text_content(manager, widget.text_element, text)
}

set_label_color :: proc(
  manager: ^Manager,
  widget: ^LabelWidget,
  color: [4]u8,
) {
  set_text_color(manager, widget.text_element, color)
}

// =============================================================================
// TextInput Widget
// =============================================================================

create_text_input :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  placeholder: string = "",
  width: f32 = 200,
  height: f32 = 36,
  max_length: u32 = 256,
) -> (
  widget: TextInputWidget,
  ok: bool,
) #optional_ok {
  // Create container
  widget.root = create_flexbox(manager, parent) or_return
  set_flexbox_size(manager, widget.root, SizeAbsolute{width, height})
  set_flexbox_padding(manager, widget.root, EdgeInsets{8, 8, 8, 8})

  // Create background
  widget.background = create_quad(
    manager,
    widget.root,
    WHITE,
    SizeRelativeParent{1.0, 1.0},
  ) or_return
  set_z_order(manager, widget.background, -0.1)

  // Create placeholder text
  widget.placeholder = create_text(
    manager,
    widget.root,
    placeholder,
    height - 16,
    TEXTBOX_PLACEHOLDER_COLOR,
  ) or_return
  widget.placeholder_text = placeholder

  // Create text (hidden initially, shown when user types)
  widget.text = create_text(
    manager,
    widget.root,
    "",
    height - 16,
    BLACK,
  ) or_return
  set_visible(manager, widget.text, false)

  // Create cursor (hidden initially)
  widget.cursor = create_quad(
    manager,
    widget.root,
    BLACK,
    SizeAbsolute{2, height - 12},
  ) or_return
  set_visible(manager, widget.cursor, false)

  // Initialize buffer
  widget.buffer = make([dynamic]u8, 0, max_length)

  // Register events
  on_click(manager, widget.background, text_input_click, &widget)
  on_event(
    manager,
    widget.background,
    .MOUSE_ENTER,
    text_input_hover_enter,
    &widget,
  )
  on_event(
    manager,
    widget.background,
    .MOUSE_LEAVE,
    text_input_hover_leave,
    &widget,
  )

  return widget, true
}

@(private)
text_input_click :: proc(event: ^Event, user_data: rawptr) {
  input := cast(^TextInputWidget)user_data
  input.focused = true
}

@(private)
text_input_hover_enter :: proc(event: ^Event, user_data: rawptr) {
  input := cast(^TextInputWidget)user_data
  input.hovered = true
}

@(private)
text_input_hover_leave :: proc(event: ^Event, user_data: rawptr) {
  input := cast(^TextInputWidget)user_data
  input.hovered = false
}

set_text_input_value :: proc(
  manager: ^Manager,
  widget: ^TextInputWidget,
  text: string,
) {
  clear(&widget.buffer)
  for ch in text {
    append(&widget.buffer, u8(ch))
  }
  widget.buffer_str = string(widget.buffer[:])

  if len(widget.buffer) > 0 {
    set_text_content(manager, widget.text, widget.buffer_str)
    set_visible(manager, widget.text, true)
    set_visible(manager, widget.placeholder, false)
  } else {
    set_visible(manager, widget.text, false)
    set_visible(manager, widget.placeholder, true)
  }
}

get_text_input_value :: proc(widget: ^TextInputWidget) -> string {
  return string(widget.buffer[:])
}

// Handle text input from keyboard
text_input_char :: proc(
  manager: ^Manager,
  widget: ^TextInputWidget,
  char: rune,
) {
  if !widget.focused do return
  if len(widget.buffer) >= cap(widget.buffer) do return

  append(&widget.buffer, u8(char))
  widget.buffer_str = string(widget.buffer[:])

  set_text_content(manager, widget.text, widget.buffer_str)
  set_visible(manager, widget.text, true)
  set_visible(manager, widget.placeholder, false)

  if widget.callback != nil {
    widget.callback(widget.user_data, widget.buffer_str)
  }
}

// Handle backspace
text_input_backspace :: proc(manager: ^Manager, widget: ^TextInputWidget) {
  if !widget.focused do return
  if len(widget.buffer) == 0 do return

  pop(&widget.buffer)
  widget.buffer_str = string(widget.buffer[:])

  if len(widget.buffer) > 0 {
    set_text_content(manager, widget.text, widget.buffer_str)
  } else {
    set_visible(manager, widget.text, false)
    set_visible(manager, widget.placeholder, true)
  }

  if widget.callback != nil {
    widget.callback(widget.user_data, widget.buffer_str)
  }
}

destroy_text_input :: proc(manager: ^Manager, widget: ^TextInputWidget) {
  delete(widget.buffer)
  destroy_flexbox(manager, widget.root, true)
}

// =============================================================================
// Dropdown Widget
// =============================================================================

create_dropdown :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  items: []string,
  width: f32 = 200,
  height: f32 = 30,
) -> (
  widget: DropdownWidget,
  ok: bool,
) #optional_ok {
  // Create main container
  widget.root = create_flexbox(manager, parent) or_return
  set_flexbox_size(manager, widget.root, SizeAbsolute{width, height})
  set_flexbox_direction(manager, widget.root, .COLUMN)

  // Selected item display
  widget.selected_bg = create_quad(
    manager,
    widget.root,
    WIDGET_DEFAULT_BG,
    SizeAbsolute{width, height},
  ) or_return
  set_z_order(manager, widget.selected_bg, -0.1)

  widget.selected_text = create_text(
    manager,
    widget.root,
    "Select...",
    height - 12,
    BLACK,
  ) or_return

  // Create dropdown list container (hidden initially)
  widget.dropdown_list = create_flexbox(manager, widget.root) or_return
  set_flexbox_size(
    manager,
    widget.dropdown_list,
    SizeAbsolute{width, f32(len(items)) * 24},
  )
  set_flexbox_direction(manager, widget.dropdown_list, .COLUMN)
  set_flexbox_visible(manager, widget.dropdown_list, false)
  set_flexbox_background(manager, widget.dropdown_list, DROPDOWN_LIST_BG)
  set_flexbox_z_order(manager, widget.dropdown_list, 10) // On top

  // Create items
  widget.item_bgs = make([dynamic]ElementHandle, len(items))
  widget.item_texts = make([dynamic]ElementHandle, len(items))

  for item, i in items {
    item_bg := create_quad(
      manager,
      widget.dropdown_list,
      DROPDOWN_LIST_BG,
      SizeAbsolute{width, 24},
    ) or_continue
    widget.item_bgs[i] = item_bg

    item_text := create_text(
      manager,
      widget.dropdown_list,
      item,
      14,
      BLACK,
    ) or_continue
    widget.item_texts[i] = item_text
  }

  widget.items = items
  widget.selected_idx = -1
  widget.hovered_item = -1

  // Register events
  on_click(manager, widget.selected_bg, dropdown_toggle, &widget)

  return widget, true
}

@(private)
dropdown_toggle :: proc(event: ^Event, user_data: rawptr) {
  dropdown := cast(^DropdownWidget)user_data
  dropdown.expanded = !dropdown.expanded
}

set_dropdown_selected :: proc(
  manager: ^Manager,
  widget: ^DropdownWidget,
  index: i32,
) {
  widget.selected_idx = index
  if index >= 0 && index < i32(len(widget.items)) {
    set_text_content(manager, widget.selected_text, widget.items[index])
  }
}

update_dropdown :: proc(manager: ^Manager, widget: ^DropdownWidget) {
  set_flexbox_visible(manager, widget.dropdown_list, widget.expanded)
}

destroy_dropdown :: proc(manager: ^Manager, widget: ^DropdownWidget) {
  delete(widget.item_bgs)
  delete(widget.item_texts)
  destroy_flexbox(manager, widget.root, true)
}

// =============================================================================
// Checkbox Widget
// =============================================================================

create_checkbox :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  label_text: string,
  checked: bool = false,
  callback: proc(ctx: rawptr, checked: bool) = nil,
  user_data: rawptr = nil,
) -> (
  widget: CheckboxWidget,
  ok: bool,
) #optional_ok {
  // Create container
  widget.root = create_flexbox(manager, parent) or_return
  set_flexbox_direction(manager, widget.root, .ROW)
  set_flexbox_align(manager, widget.root, .CENTER)
  set_flexbox_gap(manager, widget.root, 8, 0)

  // Create box
  widget.box = create_quad(
    manager,
    widget.root,
    WIDGET_DEFAULT_BG,
    SizeAbsolute{20, 20},
  ) or_return

  // Create checkmark (hidden if not checked)
  widget.checkmark = create_quad(
    manager,
    widget.root,
    BLACK,
    SizeAbsolute{12, 12},
  ) or_return
  set_visible(manager, widget.checkmark, checked)

  // Create label
  widget.label = create_text(
    manager,
    widget.root,
    label_text,
    16,
    BLACK,
  ) or_return

  widget.checked = checked
  widget.callback = callback
  widget.user_data = user_data

  // Register events
  on_click(manager, widget.box, checkbox_click, &widget)
  on_event(manager, widget.box, .MOUSE_ENTER, checkbox_hover_enter, &widget)
  on_event(manager, widget.box, .MOUSE_LEAVE, checkbox_hover_leave, &widget)

  return widget, true
}

@(private)
checkbox_click :: proc(event: ^Event, user_data: rawptr) {
  cb := cast(^CheckboxWidget)user_data
  cb.checked = !cb.checked
  if cb.callback != nil {
    cb.callback(cb.user_data, cb.checked)
  }
}

@(private)
checkbox_hover_enter :: proc(event: ^Event, user_data: rawptr) {
  cb := cast(^CheckboxWidget)user_data
  cb.hovered = true
}

@(private)
checkbox_hover_leave :: proc(event: ^Event, user_data: rawptr) {
  cb := cast(^CheckboxWidget)user_data
  cb.hovered = false
}

set_checkbox_checked :: proc(
  manager: ^Manager,
  widget: ^CheckboxWidget,
  checked: bool,
) {
  widget.checked = checked
  set_visible(manager, widget.checkmark, checked)
}

update_checkbox_appearance :: proc(
  manager: ^Manager,
  widget: ^CheckboxWidget,
) {
  set_visible(manager, widget.checkmark, widget.checked)
  if widget.hovered {
    set_quad_color(manager, widget.box, CHECKBOX_HOVER_BG)
  } else {
    set_quad_color(manager, widget.box, WIDGET_DEFAULT_BG)
  }
}
