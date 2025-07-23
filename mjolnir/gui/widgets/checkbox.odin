package gui

Checkbox :: struct {
    using widget: Widget,
    checked: bool,
    text: string,
    on_change: proc(checkbox: ^Checkbox, checked: bool),
}

checkbox_init :: proc(checkbox: ^Checkbox, id: u32, parent: ^Widget) {
    widget_init(&checkbox.widget, id, parent)
    checkbox.widget.vtable = &checkbox_vtable
    checkbox.widget.data = checkbox
    
    checkbox.checked = false
    checkbox.text = ""
}

checkbox_destroy :: proc(checkbox: ^Checkbox) {
    widget_destroy(&checkbox.widget)
}

checkbox_set_checked :: proc(checkbox: ^Checkbox, checked: bool) {
    if checkbox.checked != checked {
        checkbox.checked = checked
        widget_mark_dirty(&checkbox.widget)
        
        if checkbox.on_change != nil {
            checkbox.on_change(checkbox, checkbox.checked)
        }
    }
}

checkbox_set_text :: proc(checkbox: ^Checkbox, text: string) {
    checkbox.text = text
    widget_mark_dirty(&checkbox.widget)
}

checkbox_handle_input :: proc(widget: ^Widget, event: InputEvent) -> bool {
    checkbox := cast(^Checkbox)widget.data
    
    switch e in event {
    case MouseEvent:
        if e.type == .ButtonDown && e.button == .Left {
            if widget_contains_point(widget, e.position) {
                checkbox_set_checked(checkbox, !checkbox.checked)
                return true
            }
        }
    }
    
    return false
}

checkbox_generate_commands :: proc(widget: ^Widget, commands: ^[dynamic]UICommand) {
    checkbox := cast(^Checkbox)widget.data
    
    // Checkbox box
    box_size: f32 = 20
    box_pos := [2]f32{widget.position.x, widget.position.y + (widget.size.y - box_size) / 2}
    
    // Background
    append(commands, UICommand_Rect{
        rect = {box_pos.x, box_pos.y, box_size, box_size},
        color = {0.1, 0.1, 0.1, 1.0},
    })
    
    // Border
    border_color := [4]f32{0.3, 0.3, 0.3, 1.0}
    // Top
    append(commands, UICommand_Rect{
        rect = {box_pos.x, box_pos.y, box_size, 2},
        color = border_color,
    })
    // Bottom
    append(commands, UICommand_Rect{
        rect = {box_pos.x, box_pos.y + box_size - 2, box_size, 2},
        color = border_color,
    })
    // Left
    append(commands, UICommand_Rect{
        rect = {box_pos.x, box_pos.y, 2, box_size},
        color = border_color,
    })
    // Right
    append(commands, UICommand_Rect{
        rect = {box_pos.x + box_size - 2, box_pos.y, 2, box_size},
        color = border_color,
    })
    
    // Checkmark
    if checkbox.checked {
        // Draw a simple checkmark using two rectangles
        check_color := [4]f32{0.3, 0.8, 0.3, 1.0}
        
        // First line of checkmark (short diagonal)
        append(commands, UICommand_Rect{
            rect = {box_pos.x + 4, box_pos.y + 10, 6, 3},
            color = check_color,
        })
        
        // Second line of checkmark (long diagonal)
        append(commands, UICommand_Rect{
            rect = {box_pos.x + 8, box_pos.y + 6, 3, 10},
            color = check_color,
        })
    }
    
    // Label text
    if len(checkbox.text) > 0 {
        text_pos := [2]f32{
            box_pos.x + box_size + 8,
            widget.position.y + (widget.size.y - 16) / 2,
        }
        
        append(commands, UICommand_Text{
            text = checkbox.text,
            position = text_pos,
            color = {1.0, 1.0, 1.0, 1.0},
            font_size = 16,
            font_id = 0,
        })
    }
}

checkbox_vtable := WidgetVTable{
    destroy = cast(proc(^Widget))checkbox_destroy,
    update = widget_update_default,
    handle_input = checkbox_handle_input,
    generate_commands = checkbox_generate_commands,
}