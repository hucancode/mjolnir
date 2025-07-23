package gui

Widget :: struct {
    id: u32,
    dirty: bool,
    enabled: bool,
    visible: bool,
    position: [2]f32,
    size: [2]f32,
    z_order: i32,
    parent: ^Widget,
    children: [dynamic]^Widget,
    vtable: ^WidgetVTable,
    data: rawptr,
}

WidgetVTable :: struct {
    generate_commands: proc(widget: ^Widget, commands: ^[dynamic]UICommand),
    handle_input: proc(widget: ^Widget, event: InputEvent) -> bool,
    update: proc(widget: ^Widget, dt: f32),
    destroy: proc(widget: ^Widget),
}

LayoutType :: enum {
    None,
    Horizontal,
    Vertical,
    Grid,
}

TextAlignment :: enum {
    Left,
    Center,
    Right,
}

widget_init :: proc(widget: ^Widget, vtable: ^WidgetVTable, data: rawptr) {
    widget.id = 0
    widget.dirty = true
    widget.enabled = true
    widget.visible = true
    widget.position = {0, 0}
    widget.size = {100, 100}
    widget.z_order = 0
    widget.parent = nil
    widget.children = make([dynamic]^Widget, 0, 8)
    widget.vtable = vtable
    widget.data = data
}

widget_set_position :: proc(widget: ^Widget, x, y: f32) {
    widget.position = {x, y}
    widget.dirty = true
}

widget_set_size :: proc(widget: ^Widget, width, height: f32) {
    widget.size = {width, height}
    widget.dirty = true
}

widget_set_visible :: proc(widget: ^Widget, visible: bool) {
    widget.visible = visible
    widget.dirty = true
}

widget_set_enabled :: proc(widget: ^Widget, enabled: bool) {
    widget.enabled = enabled
    widget.dirty = true
}

widget_add_child :: proc(parent: ^Widget, child: ^Widget) {
    append(&parent.children, child)
    child.parent = parent
    parent.dirty = true
}

widget_remove_child :: proc(parent: ^Widget, child: ^Widget) {
    for c, i in parent.children {
        if c == child {
            ordered_remove(&parent.children, i)
            child.parent = nil
            parent.dirty = true
            break
        }
    }
}

widget_get_absolute_position :: proc(widget: ^Widget) -> [2]f32 {
    pos := widget.position
    current := widget.parent
    for current != nil {
        pos += current.position
        current = current.parent
    }
    return pos
}

widget_contains_point :: proc(widget: ^Widget, point: [2]f32) -> bool {
    abs_pos := widget_get_absolute_position(widget)
    return point.x >= abs_pos.x && point.x <= abs_pos.x + widget.size.x &&
           point.y >= abs_pos.y && point.y <= abs_pos.y + widget.size.y
}

widget_generate_commands :: proc(widget: ^Widget, commands: ^[dynamic]UICommand) {
    if !widget.visible do return
    if widget.vtable != nil && widget.vtable.generate_commands != nil {
        widget.vtable.generate_commands(widget, commands)
    }
    for child in widget.children {
        widget_generate_commands(child, commands)
    }
}

widget_handle_input :: proc(widget: ^Widget, event: InputEvent) -> bool {
    if !widget.visible || !widget.enabled do return false
    for i := len(widget.children) - 1; i >= 0; i -= 1 {
        if widget_handle_input(widget.children[i], event) do return true
    }
    if widget.vtable != nil && widget.vtable.handle_input != nil {
        return widget.vtable.handle_input(widget, event)
    }
    return false
}

widget_update :: proc(widget: ^Widget, dt: f32) {
    if !widget.visible do return
    if widget.vtable != nil && widget.vtable.update != nil {
        widget.vtable.update(widget, dt)
    }
    for child in widget.children {
        widget_update(child, dt)
    }
}

widget_destroy :: proc(widget: ^Widget) {
    for child in widget.children {
        widget_destroy(child)
    }
    delete(widget.children)
    if widget.vtable != nil && widget.vtable.destroy != nil {
        widget.vtable.destroy(widget)
    }
}