package widgets

import ".."
import "core:strings"

ButtonWidget :: struct {
    using base: gui.Widget,
    text: string,
    font_id: u32,
    font_size: f32,
    text_color: [4]f32,
    is_hovered: bool,
    is_pressed: bool,
    is_disabled: bool,
    on_click: proc(button: ^ButtonWidget),
}

button_vtable := gui.WidgetVTable{
    generate_commands = button_generate_commands,
    handle_input = button_handle_input,
    update = button_update,
    destroy = button_destroy,
}

create_button :: proc(system: ^gui.GUISystem, text: string, position: [2]f32, size: [2]f32) -> ^ButtonWidget {
    button := new(ButtonWidget)
    gui.widget_init(&button.base, &button_vtable, button)
    
    button.text = strings.clone(text)
    button.font_id = 0
    button.font_size = 14.0
    button.text_color = {1, 1, 1, 1}
    button.position = position
    button.size = size
    button.is_hovered = false
    button.is_pressed = false
    button.is_disabled = false
    button.on_click = nil
    
    gui.gui_system_add_widget(system, &button.base)
    
    return button
}

button_set_text :: proc(button: ^ButtonWidget, text: string) {
    if button.text != text {
        delete(button.text)
        button.text = strings.clone(text)
        button.dirty = true
    }
}

button_set_enabled :: proc(button: ^ButtonWidget, enabled: bool) {
    if button.is_disabled == enabled {
        button.is_disabled = !enabled
        button.dirty = true
    }
}

button_set_on_click :: proc(button: ^ButtonWidget, callback: proc(button: ^ButtonWidget)) {
    button.on_click = callback
}

button_generate_commands :: proc(widget: ^gui.Widget, commands: ^[dynamic]gui.UICommand) {
    button := cast(^ButtonWidget)widget.data
    
    region: gui.UIAtlasRegion
    default_atlas := gui.create_default_atlas_layout()
    
    if button.is_disabled {
        region = default_atlas.button_disabled
    } else if button.is_pressed {
        region = default_atlas.button_pressed
    } else if button.is_hovered {
        region = default_atlas.button_hover
    } else {
        region = default_atlas.button_normal
    }
    
    cmd_bg := gui.UICommand_AtlasImage{
        rect = {widget.position.x, widget.position.y, widget.size.x, widget.size.y},
        atlas_region = region,
        color = {1, 1, 1, 1},
    }
    append(commands, cmd_bg)
    
    if button.text != "" {
        text_pos := widget.position + widget.size / 2
        cmd_text := gui.UICommand_Text{
            text = button.text,
            position = text_pos,
            font_id = button.font_id,
            font_size = button.font_size,
            color = button.text_color,
        }
        append(commands, cmd_text)
    }
}

button_handle_input :: proc(widget: ^gui.Widget, event: gui.InputEvent) -> bool {
    button := cast(^ButtonWidget)widget.data
    
    if button.is_disabled do return false
    
    switch e in event {
    case gui.MouseEvent:
        switch e.type {
        case .Enter:
            button.is_hovered = true
            button.dirty = true
            return true
        case .Leave:
            button.is_hovered = false
            button.is_pressed = false
            button.dirty = true
            return true
        case .ButtonDown:
            if e.button == .Left && button.is_hovered {
                button.is_pressed = true
                button.dirty = true
                return true
            }
        case .ButtonUp:
            if e.button == .Left && button.is_pressed {
                button.is_pressed = false
                button.dirty = true
                if button.is_hovered && button.on_click != nil {
                    button.on_click(button)
                }
                return true
            }
        }
    }
    
    return false
}

button_update :: proc(widget: ^gui.Widget, dt: f32) {
}

button_destroy :: proc(widget: ^gui.Widget) {
    button := cast(^ButtonWidget)widget.data
    delete(button.text)
}