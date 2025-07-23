package gui

import "core:strings"
import "core:unicode/utf8"

TextInput :: struct {
    using widget: Widget,
    text: strings.Builder,
    placeholder: string,
    cursor_pos: int,
    selection_start: int,
    selection_end: int,
    is_focused: bool,
    is_password: bool,
    max_length: int,
    on_change: proc(text_input: ^TextInput, text: string),
    on_submit: proc(text_input: ^TextInput, text: string),
}

text_input_init :: proc(text_input: ^TextInput, id: u32, parent: ^Widget) {
    widget_init(&text_input.widget, id, parent)
    text_input.widget.vtable = &text_input_vtable
    text_input.widget.data = text_input
    
    strings.builder_init(&text_input.text)
    text_input.placeholder = ""
    text_input.cursor_pos = 0
    text_input.selection_start = -1
    text_input.selection_end = -1
    text_input.is_focused = false
    text_input.is_password = false
    text_input.max_length = 256
}

text_input_destroy :: proc(text_input: ^TextInput) {
    strings.builder_destroy(&text_input.text)
    widget_destroy(&text_input.widget)
}

text_input_set_text :: proc(text_input: ^TextInput, text: string) {
    strings.builder_reset(&text_input.text)
    strings.write_string(&text_input.text, text)
    text_input.cursor_pos = len(text)
    text_input.selection_start = -1
    text_input.selection_end = -1
    widget_mark_dirty(&text_input.widget)
    
    if text_input.on_change != nil {
        text_input.on_change(text_input, text)
    }
}

text_input_get_text :: proc(text_input: ^TextInput) -> string {
    return strings.to_string(text_input.text)
}

text_input_set_placeholder :: proc(text_input: ^TextInput, placeholder: string) {
    text_input.placeholder = placeholder
    widget_mark_dirty(&text_input.widget)
}

text_input_handle_input :: proc(widget: ^Widget, event: InputEvent) -> bool {
    text_input := cast(^TextInput)widget.data
    
    switch e in event {
    case MouseEvent:
        if e.type == .ButtonDown && e.button == .Left {
            if widget_contains_point(widget, e.position) {
                text_input.is_focused = true
                // TODO: Calculate cursor position from mouse position
                widget_mark_dirty(widget)
                return true
            } else {
                text_input.is_focused = false
                widget_mark_dirty(widget)
            }
        }
        
    case KeyboardEvent:
        if !text_input.is_focused do return false
        
        if e.type == .Character && e.character != 0 {
            // Insert character at cursor position
            text := strings.to_string(text_input.text)
            if len(text) < text_input.max_length {
                // Simple implementation - rebuild string
                new_text := strings.builder_make()
                defer strings.builder_destroy(&new_text)
                
                strings.write_string(&new_text, text[:text_input.cursor_pos])
                strings.write_rune(&new_text, e.character)
                strings.write_string(&new_text, text[text_input.cursor_pos:])
                
                text_input_set_text(text_input, strings.to_string(new_text))
                text_input.cursor_pos += 1
            }
            return true
        } else if e.type == .KeyDown {
            switch e.key {
            case KEY_BACKSPACE:
                if text_input.cursor_pos > 0 {
                    text := strings.to_string(text_input.text)
                    new_text := strings.builder_make()
                    defer strings.builder_destroy(&new_text)
                    
                    strings.write_string(&new_text, text[:text_input.cursor_pos-1])
                    strings.write_string(&new_text, text[text_input.cursor_pos:])
                    
                    text_input_set_text(text_input, strings.to_string(new_text))
                    text_input.cursor_pos -= 1
                }
                return true
                
            case KEY_DELETE:
                text := strings.to_string(text_input.text)
                if text_input.cursor_pos < len(text) {
                    new_text := strings.builder_make()
                    defer strings.builder_destroy(&new_text)
                    
                    strings.write_string(&new_text, text[:text_input.cursor_pos])
                    strings.write_string(&new_text, text[text_input.cursor_pos+1:])
                    
                    text_input_set_text(text_input, strings.to_string(new_text))
                }
                return true
                
            case KEY_LEFT:
                if text_input.cursor_pos > 0 {
                    text_input.cursor_pos -= 1
                    widget_mark_dirty(widget)
                }
                return true
                
            case KEY_RIGHT:
                text := strings.to_string(text_input.text)
                if text_input.cursor_pos < len(text) {
                    text_input.cursor_pos += 1
                    widget_mark_dirty(widget)
                }
                return true
                
            case KEY_HOME:
                text_input.cursor_pos = 0
                widget_mark_dirty(widget)
                return true
                
            case KEY_END:
                text_input.cursor_pos = len(strings.to_string(text_input.text))
                widget_mark_dirty(widget)
                return true
                
            case KEY_ENTER:
                if text_input.on_submit != nil {
                    text_input.on_submit(text_input, strings.to_string(text_input.text))
                }
                return true
            }
        }
    }
    
    return false
}

text_input_generate_commands :: proc(widget: ^Widget, commands: ^[dynamic]UICommand) {
    text_input := cast(^TextInput)widget.data
    
    // Background
    bg_color := text_input.is_focused ? [4]f32{0.15, 0.15, 0.15, 1.0} : [4]f32{0.1, 0.1, 0.1, 1.0}
    append(commands, UICommand_Rect{
        rect = {widget.position.x, widget.position.y, widget.size.x, widget.size.y},
        color = bg_color,
    })
    
    // Border
    border_color := text_input.is_focused ? [4]f32{0.4, 0.6, 1.0, 1.0} : [4]f32{0.3, 0.3, 0.3, 1.0}
    // Top border
    append(commands, UICommand_Rect{
        rect = {widget.position.x, widget.position.y, widget.size.x, 2},
        color = border_color,
    })
    // Bottom border
    append(commands, UICommand_Rect{
        rect = {widget.position.x, widget.position.y + widget.size.y - 2, widget.size.x, 2},
        color = border_color,
    })
    // Left border
    append(commands, UICommand_Rect{
        rect = {widget.position.x, widget.position.y, 2, widget.size.y},
        color = border_color,
    })
    // Right border
    append(commands, UICommand_Rect{
        rect = {widget.position.x + widget.size.x - 2, widget.position.y, 2, widget.size.y},
        color = border_color,
    })
    
    // Text or placeholder
    text := strings.to_string(text_input.text)
    display_text := text
    text_color := [4]f32{1.0, 1.0, 1.0, 1.0}
    
    if len(text) == 0 && !text_input.is_focused {
        display_text = text_input.placeholder
        text_color = [4]f32{0.5, 0.5, 0.5, 1.0}
    } else if text_input.is_password {
        // Replace with asterisks
        pwd_builder := strings.builder_make()
        defer strings.builder_destroy(&pwd_builder)
        for _ in 0..<len(text) {
            strings.write_rune(&pwd_builder, '*')
        }
        display_text = strings.to_string(pwd_builder)
    }
    
    if len(display_text) > 0 {
        text_pos := [2]f32{
            widget.position.x + 5,
            widget.position.y + (widget.size.y - 16) / 2,
        }
        
        append(commands, UICommand_Text{
            text = display_text,
            position = text_pos,
            color = text_color,
            font_size = 16,
            font_id = 0,
        })
    }
    
    // Cursor
    if text_input.is_focused {
        cursor_x := widget.position.x + 5 + f32(text_input.cursor_pos * 8) // Assuming 8px per char
        append(commands, UICommand_Rect{
            rect = {cursor_x, widget.position.y + 4, 2, widget.size.y - 8},
            color = {1.0, 1.0, 1.0, 1.0},
        })
    }
}

text_input_vtable := WidgetVTable{
    destroy = cast(proc(^Widget))text_input_destroy,
    update = widget_update_default,
    handle_input = text_input_handle_input,
    generate_commands = text_input_generate_commands,
}