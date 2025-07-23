package gui

import "core:math"
import "core:fmt"

Slider :: struct {
    using widget: Widget,
    value: f32,
    min_value: f32,
    max_value: f32,
    step: f32,
    is_dragging: bool,
    is_horizontal: bool,
    show_value: bool,
    on_change: proc(slider: ^Slider, value: f32),
}

slider_init :: proc(slider: ^Slider, id: u32, parent: ^Widget) {
    widget_init(&slider.widget, id, parent)
    slider.widget.vtable = &slider_vtable
    slider.widget.data = slider
    
    slider.value = 0.0
    slider.min_value = 0.0
    slider.max_value = 1.0
    slider.step = 0.01
    slider.is_dragging = false
    slider.is_horizontal = true
    slider.show_value = true
}

slider_destroy :: proc(slider: ^Slider) {
    widget_destroy(&slider.widget)
}

slider_set_value :: proc(slider: ^Slider, value: f32) {
    clamped_value := math.clamp(value, slider.min_value, slider.max_value)
    
    // Snap to step
    if slider.step > 0 {
        steps := (clamped_value - slider.min_value) / slider.step
        clamped_value = slider.min_value + math.round(steps) * slider.step
    }
    
    if slider.value != clamped_value {
        slider.value = clamped_value
        widget_mark_dirty(&slider.widget)
        
        if slider.on_change != nil {
            slider.on_change(slider, slider.value)
        }
    }
}

slider_set_range :: proc(slider: ^Slider, min_value, max_value: f32) {
    slider.min_value = min_value
    slider.max_value = max_value
    slider_set_value(slider, slider.value) // Re-clamp current value
}

slider_handle_input :: proc(widget: ^Widget, event: InputEvent) -> bool {
    slider := cast(^Slider)widget.data
    
    switch e in event {
    case MouseEvent:
        switch e.type {
        case .ButtonDown:
            if e.button == .Left && widget_contains_point(widget, e.position) {
                slider.is_dragging = true
                // Calculate value from position
                update_slider_from_position(slider, e.position)
                return true
            }
            
        case .ButtonUp:
            if e.button == .Left && slider.is_dragging {
                slider.is_dragging = false
                return true
            }
            
        case .Move:
            if slider.is_dragging {
                update_slider_from_position(slider, e.position)
                return true
            }
        }
    }
    
    return false
}

update_slider_from_position :: proc(slider: ^Slider, pos: [2]f32) {
    if slider.is_horizontal {
        // Horizontal slider
        track_start := slider.widget.position.x + 10
        track_end := slider.widget.position.x + slider.widget.size.x - 10
        track_width := track_end - track_start
        
        if track_width > 0 {
            t := math.clamp((pos.x - track_start) / track_width, 0.0, 1.0)
            new_value := slider.min_value + t * (slider.max_value - slider.min_value)
            slider_set_value(slider, new_value)
        }
    } else {
        // Vertical slider
        track_start := slider.widget.position.y + 10
        track_end := slider.widget.position.y + slider.widget.size.y - 10
        track_height := track_end - track_start
        
        if track_height > 0 {
            // Invert for vertical (top = max, bottom = min)
            t := 1.0 - math.clamp((pos.y - track_start) / track_height, 0.0, 1.0)
            new_value := slider.min_value + t * (slider.max_value - slider.min_value)
            slider_set_value(slider, new_value)
        }
    }
}

slider_generate_commands :: proc(widget: ^Widget, commands: ^[dynamic]UICommand) {
    slider := cast(^Slider)widget.data
    
    // Calculate normalized value
    t := (slider.value - slider.min_value) / (slider.max_value - slider.min_value)
    t = math.clamp(t, 0.0, 1.0)
    
    if slider.is_horizontal {
        // Horizontal slider track
        track_y := widget.position.y + widget.size.y/2 - 2
        append(commands, UICommand_Rect{
            rect = {widget.position.x + 10, track_y, widget.size.x - 20, 4},
            color = {0.2, 0.2, 0.2, 1.0},
        })
        
        // Filled portion
        filled_width := (widget.size.x - 20) * t
        append(commands, UICommand_Rect{
            rect = {widget.position.x + 10, track_y, filled_width, 4},
            color = {0.3, 0.5, 0.8, 1.0},
        })
        
        // Handle
        handle_x := widget.position.x + 10 + (widget.size.x - 20) * t
        handle_color := slider.is_dragging ? [4]f32{0.5, 0.7, 1.0, 1.0} : [4]f32{0.8, 0.8, 0.8, 1.0}
        append(commands, UICommand_Rect{
            rect = {handle_x - 8, widget.position.y + widget.size.y/2 - 8, 16, 16},
            color = handle_color,
        })
    } else {
        // Vertical slider track
        track_x := widget.position.x + widget.size.x/2 - 2
        append(commands, UICommand_Rect{
            rect = {track_x, widget.position.y + 10, 4, widget.size.y - 20},
            color = {0.2, 0.2, 0.2, 1.0},
        })
        
        // Filled portion (from bottom up)
        filled_height := (widget.size.y - 20) * t
        filled_y := widget.position.y + widget.size.y - 10 - filled_height
        append(commands, UICommand_Rect{
            rect = {track_x, filled_y, 4, filled_height},
            color = {0.3, 0.5, 0.8, 1.0},
        })
        
        // Handle
        handle_y := widget.position.y + 10 + (widget.size.y - 20) * (1.0 - t)
        handle_color := slider.is_dragging ? [4]f32{0.5, 0.7, 1.0, 1.0} : [4]f32{0.8, 0.8, 0.8, 1.0}
        append(commands, UICommand_Rect{
            rect = {widget.position.x + widget.size.x/2 - 8, handle_y - 8, 16, 16},
            color = handle_color,
        })
    }
    
    // Value text
    if slider.show_value {
        value_text: string
        if slider.step >= 1.0 {
            value_text = fmt.aprintf("%d", int(slider.value))
        } else {
            value_text = fmt.aprintf("%.2f", slider.value)
        }
        defer delete(value_text)
        
        text_size := measure_text(value_text, 1.0)
        text_pos: [2]f32
        
        if slider.is_horizontal {
            text_pos = {
                widget.position.x + widget.size.x - text_size.x - 5,
                widget.position.y + 2,
            }
        } else {
            text_pos = {
                widget.position.x + (widget.size.x - text_size.x) / 2,
                widget.position.y + widget.size.y - 20,
            }
        }
        
        append(commands, UICommand_Text{
            text = value_text,
            position = text_pos,
            color = {0.8, 0.8, 0.8, 1.0},
            font_size = 14,
            font_id = 0,
        })
    }
}

slider_vtable := WidgetVTable{
    destroy = cast(proc(^Widget))slider_destroy,
    update = widget_update_default,
    handle_input = slider_handle_input,
    generate_commands = slider_generate_commands,
}