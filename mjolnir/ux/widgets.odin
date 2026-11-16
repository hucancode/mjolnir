package ux

// Theme is the styles the widget procs give their nodes.
Theme :: struct {
  text:     StyleHandle, // labels
  button:   StyleHandle,
  field:    StyleHandle, // text boxes
  window:   StyleHandle,
  title:    StyleHandle, // a window's title bar
  heading:  StyleHandle, // a window's title
  close:    StyleHandle, // a window's close button
  check:    StyleHandle, // a check's box: its ACTIVE look is checked
  track:    StyleHandle, // a slider's bar
  knob:     StyleHandle,
  panel:    StyleHandle, // scroll views
}

// theme_create adds a plain dark look for every widget part and returns it; init sets UI.theme
// to one.
theme_create :: proc(self: ^UI) -> Theme {
  WHITE :: [4]u8{235, 235, 242, 255}
  EDGE :: [4]u8{74, 80, 104, 255}
  LIT :: [4]u8{130, 140, 180, 255}
  BACK :: [4]u8{12, 14, 20, 235}
  button := Style{fill = {48, 54, 74, 255}, border = 1, border_color = {88, 96, 124, 255}, color = WHITE}
  hover, press, active := button, button, button
  hover.fill, hover.border_color = {66, 74, 100, 255}, LIT
  press.fill = {34, 38, 52, 255}
  active.fill = {72, 96, 160, 255}
  field := Style{fill = BACK, border = 1, border_color = EDGE, color = WHITE}
  field_hover := field
  field_hover.border_color = LIT
  check := field
  check_on := check
  check_on.fill = {90, 140, 230, 255}
  knob := Style{fill = {180, 186, 200, 255}}
  knob_hover := Style{fill = {225, 228, 238, 255}}
  return {
    text = style_create(self, {color = WHITE}),
    button = style_create(self, button, hover, press, active),
    field = style_create(self, field, field_hover),
    window = style_create(self, {fill = {20, 22, 32, 245}, border = 1, border_color = EDGE}),
    title = style_create(self, {fill = {34, 38, 52, 255}}),
    heading = style_create(self, {color = WHITE}),
    close = style_create(self, {color = {200, 200, 210, 255}}, Style{fill = {170, 50, 45, 255}, color = WHITE}),
    check = style_create(self, check, field_hover, nil, check_on),
    track = style_create(self, {fill = BACK, border = 1, border_color = EDGE}),
    knob = style_create(self, knob, knob_hover),
    panel = style_create(self, {fill = BACK, border = 1, border_color = EDGE}),
  }
}

// label adds a line of text, `size` big (0: UI.font_size), in `style` (0: the theme's text).
label :: proc(self: ^UI, parent: NodeHandle, text: string, size: f32 = 0, style: StyleHandle = 0) -> NodeHandle {
  return node_create(self, {parent = parent, text = text, font_size = size, style = style if style != 0 else self.theme.text})
}

// button adds a button around `text`, its size fitting the text unless given; read it with
// clicked.
button :: proc(self: ^UI, parent: NodeHandle, text: string, size: [2]Size = {}) -> NodeHandle {
  b := node_create(self, {parent = parent, size = size, padding = {14, 6, 14, 6}, align = {.CENTER, .CENTER}, interactive = true, style = self.theme.button})
  label(self, b, text)
  return b
}

// check adds a box and `text` that a click checks and unchecks: read its Node.active (and
// changed, the tick it flips).
check :: proc(self: ^UI, parent: NodeHandle, text: string, on := false) -> NodeHandle {
  row := node_create(self, {parent = parent, gap = 8, align = {.START, .CENTER}, interactive = true, toggle = true, active = on})
  node_create(self, {parent = row, size = fixed(18, 18), style = self.theme.check})
  label(self, row, text)
  return row
}

// text_box adds a one-line text the user types into, `width` wide: its Node.text is what was
// typed (changed each edit, submitted on Enter).
text_box :: proc(self: ^UI, parent: NodeHandle, text := "", width: f32 = 200) -> NodeHandle {
  return node_create(self, {parent = parent, text = text, size = {{.FIXED, width}, {}}, padding = {8, 5, 8, 5}, align = {.START, .CENTER}, clip = true, editable = true, interactive = true, style = self.theme.field})
}

// slider adds a bar `width` wide with a knob dragged along it, starting at `value` (0..1); the
// knob's Node.anchor.x is the value (changed while it moves). It returns the knob.
slider :: proc(self: ^UI, parent: NodeHandle, value: f32 = 0, width: f32 = 160) -> (knob: NodeHandle) {
  track := node_create(self, {parent = parent, size = fixed(width, 20)})
  node_create(self, {parent = track, position = .ABSOLUTE, anchor = {0, 0.5}, size = {percent(1), {.FIXED, 6}}, style = self.theme.track})
  knob = node_create(self, {parent = track, position = .ABSOLUTE, anchor = {clamp(value, 0, 1), 0.5}, size = fixed(12, 20), interactive = true, style = self.theme.knob})
  node(self, knob).drags = knob
  return
}

// window adds a root window `width` wide at `offset` (reference units, as a root's): a title bar
// that drags it, a close button that hides it (show it again with Node.hidden), coming to the
// front when pressed. Add its content to `body`.
window :: proc(self: ^UI, title: string, width: f32, offset: [2]f32 = {}) -> (root, body, close: NodeHandle) {
  root = node_create(self, {direction = .COLUMN, size = {{.FIXED, width}, {}}, offset = offset, interactive = true, front = true, style = self.theme.window})
  bar := node_create(self, {parent = root, size = {grow(), {.FIXED, 32}}, padding = {12, 0, 5, 0}, align = {.START, .CENTER}, interactive = true, drags = root, style = self.theme.title})
  label(self, bar, title, style = self.theme.heading)
  node_create(self, {parent = bar, size = {grow(), {}}})
  close = node_create(self, {parent = bar, size = fixed(22, 22), align = {.CENTER, .CENTER}, interactive = true, hides = root, style = self.theme.close})
  label(self, close, "x")
  body = node_create(self, {parent = root, direction = .COLUMN, size = {grow(), {}}, padding = {14, 12, 14, 14}, gap = 10})
  return
}

// scroll_view adds a column `size` big that clips its content and scrolls it with the wheel.
scroll_view :: proc(self: ^UI, parent: NodeHandle, size: [2]Size) -> NodeHandle {
  return node_create(self, {parent = parent, direction = .COLUMN, size = size, padding = {4, 4, 4, 4}, gap = 4, clip = true, interactive = true, style = self.theme.panel})
}
