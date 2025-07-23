package widgets

import ".."
import "core:strings"

LabelWidget :: struct {
    using base: gui.Widget,
    text: string,
    font_id: u32,
    font_size: f32,
    color: [4]f32,
    alignment: gui.TextAlignment,
}

label_vtable := gui.WidgetVTable{
    generate_commands = label_generate_commands,
    handle_input = label_handle_input,
    update = label_update,
    destroy = label_destroy,
}

create_label :: proc(system: ^gui.GUISystem, text: string, position: [2]f32) -> ^LabelWidget {
    label := new(LabelWidget)
    gui.widget_init(&label.base, &label_vtable, label)
    
    label.text = strings.clone(text)
    label.font_id = 0
    label.font_size = 16.0
    label.color = {1, 1, 1, 1}
    label.alignment = .Left
    label.position = position
    label.size = {100, 20}
    
    gui.gui_system_add_widget(system, &label.base)
    
    return label
}

label_set_text :: proc(label: ^LabelWidget, text: string) {
    if label.text != text {
        delete(label.text)
        label.text = strings.clone(text)
        label.dirty = true
    }
}

label_set_font :: proc(label: ^LabelWidget, font_id: u32, font_size: f32) {
    if label.font_id != font_id || label.font_size != font_size {
        label.font_id = font_id
        label.font_size = font_size
        label.dirty = true
    }
}

label_set_color :: proc(label: ^LabelWidget, color: [4]f32) {
    label.color = color
    label.dirty = true
}

label_set_alignment :: proc(label: ^LabelWidget, alignment: gui.TextAlignment) {
    if label.alignment != alignment {
        label.alignment = alignment
        label.dirty = true
    }
}

label_generate_commands :: proc(widget: ^gui.Widget, commands: ^[dynamic]gui.UICommand) {
    label := cast(^LabelWidget)widget.data
    
    if label.text != "" {
        text_pos := widget.position
        switch label.alignment {
        case .Left:
            text_pos = widget.position
        case .Center:
            text_pos = widget.position + {widget.size.x / 2, widget.size.y / 2}
        case .Right:
            text_pos = widget.position + {widget.size.x, widget.size.y / 2}
        }
        
        cmd := gui.UICommand_Text{
            text = label.text,
            position = text_pos,
            font_id = label.font_id,
            font_size = label.font_size,
            color = label.color,
        }
        append(commands, cmd)
    }
}

label_handle_input :: proc(widget: ^gui.Widget, event: gui.InputEvent) -> bool {
    return false
}

label_update :: proc(widget: ^gui.Widget, dt: f32) {
}

label_destroy :: proc(widget: ^gui.Widget) {
    label := cast(^LabelWidget)widget.data
    delete(label.text)
}