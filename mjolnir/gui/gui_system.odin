package gui

import "../gpu"
import vk "vendor:vulkan"
import "core:log"
import "core:mem"
import "core:slice"

GUISystem :: struct {
    commands: [dynamic]UICommand,
    command_generation_id: u64,
    widgets: [dynamic]^Widget,
    widget_id_counter: u32,
    focused_widget: ^Widget,
    hovered_widget: ^Widget,
    input_state: InputState,
    atlas_texture: ^gpu.ImageBuffer,
    atlas_regions: UIAtlasRegions,
    font_system: FontSystem,
    renderer: ^GUIRenderer,
    gpu_context: ^gpu.GPUContext,
}


gui_system_init :: proc(system: ^GUISystem, gpu_context: ^gpu.GPUContext, atlas_texture: ^gpu.ImageBuffer, font_texture: ^gpu.ImageBuffer) -> bool {
    system.commands = make([dynamic]UICommand, 0, 1024)
    system.command_generation_id = 0
    system.widgets = make([dynamic]^Widget, 0, 128)
    system.widget_id_counter = 0
    system.focused_widget = nil
    system.hovered_widget = nil
    system.gpu_context = gpu_context
    
    input_state_init(&system.input_state)
    
    system.atlas_regions = create_default_atlas_layout()
    
    // Store provided atlas texture
    system.atlas_texture = atlas_texture
    if system.atlas_texture == nil {
        log.error("GUI atlas texture is nil")
        return false
    }
    
    if !font_system_init(&system.font_system, gpu_context, font_texture) {
        log.error("Failed to initialize font system")
        return false
    }
    
    system.renderer = new(GUIRenderer)
    if gui_renderer_init(system.renderer, gpu_context) != .SUCCESS {
        log.error("Failed to initialize GUI renderer")
        font_system_destroy(&system.font_system)
        free(system.renderer)
        return false
    }
    
    return true
}

gui_system_destroy :: proc(system: ^GUISystem) {
    for widget in system.widgets {
        widget_destroy(widget)
    }
    delete(system.widgets)
    delete(system.commands)
    
    font_system_destroy(&system.font_system)
    
    if system.renderer != nil {
        gui_renderer_destroy(system.renderer, system.gpu_context)
        free(system.renderer)
    }
    
    if system.atlas_texture != nil {
        // TODO: Clean up atlas texture
    // gpu.image_buffer_destroy(system.atlas_texture)
    }
}

gui_system_load_atlas :: proc(system: ^GUISystem, path: string) -> bool {
    return false
}

gui_system_add_widget :: proc(system: ^GUISystem, widget: ^Widget) -> u32 {
    widget.id = system.widget_id_counter
    system.widget_id_counter += 1
    append(&system.widgets, widget)
    return widget.id
}

gui_system_remove_widget :: proc(system: ^GUISystem, widget: ^Widget) {
    for w, i in system.widgets {
        if w == widget {
            ordered_remove(&system.widgets, i)
            widget_destroy(widget)
            break
        }
    }
}

gui_system_handle_mouse_move :: proc(system: ^GUISystem, x, y: f32) {
    input_state_update_mouse_pos(&system.input_state, x, y)
    
    event := MouseEvent{
        type = .Move,
        position = {x, y},
    }
    
    new_hovered: ^Widget = nil
    for widget in system.widgets {
        if widget_contains_point(widget, {x, y}) {
            new_hovered = widget
        }
    }
    
    if new_hovered != system.hovered_widget {
        if system.hovered_widget != nil {
            leave_event := MouseEvent{
                type = .Leave,
                position = {x, y},
            }
            widget_handle_input(system.hovered_widget, leave_event)
        }
        
        if new_hovered != nil {
            enter_event := MouseEvent{
                type = .Enter,
                position = {x, y},
            }
            widget_handle_input(new_hovered, enter_event)
        }
        
        system.hovered_widget = new_hovered
    }
    
    for widget in system.widgets {
        widget_handle_input(widget, event)
    }
}

gui_system_handle_mouse_button :: proc(system: ^GUISystem, button: MouseButton, pressed: bool) {
    input_state_update_mouse_button(&system.input_state, button, pressed)
    
    event := MouseEvent{
        type = pressed ? .ButtonDown : .ButtonUp,
        position = system.input_state.mouse_pos,
        button = button,
    }
    
    if pressed && button == .Left {
        system.focused_widget = nil
        for i := len(system.widgets) - 1; i >= 0; i -= 1 {
            if widget_contains_point(system.widgets[i], system.input_state.mouse_pos) {
                system.focused_widget = system.widgets[i]
                break
            }
        }
    }
    
    for i := len(system.widgets) - 1; i >= 0; i -= 1 {
        if widget_handle_input(system.widgets[i], event) do break
    }
}

gui_system_handle_key :: proc(system: ^GUISystem, key: i32, pressed: bool) {
    event := KeyboardEvent{
        type = pressed ? .KeyDown : .KeyUp,
        key = key,
        modifiers = system.input_state.key_modifiers,
    }
    
    if system.focused_widget != nil {
        widget_handle_input(system.focused_widget, event)
    }
}

gui_system_handle_char :: proc(system: ^GUISystem, char: rune) {
    event := KeyboardEvent{
        type = .Character,
        character = char,
        modifiers = system.input_state.key_modifiers,
    }
    
    if system.focused_widget != nil {
        widget_handle_input(system.focused_widget, event)
    }
}

gui_system_update :: proc(system: ^GUISystem, dt: f32) {
    for widget in system.widgets {
        widget_update(widget, dt)
    }
}

gui_system_generate_commands :: proc(system: ^GUISystem) {
    clear(&system.commands)
    
    slice.sort_by(system.widgets[:], proc(a, b: ^Widget) -> bool {
        return a.z_order < b.z_order
    })
    
    for widget in system.widgets {
        if widget.dirty {
            widget_generate_commands(widget, &system.commands)
            widget.dirty = false
        }
    }
    
    system.command_generation_id += 1
}

gui_system_render :: proc(system: ^GUISystem, command_buffer: vk.CommandBuffer) {
    font_system_update_texture(&system.font_system)
    
    if system.renderer != nil {
        gui_renderer_render(system.renderer, command_buffer, system.commands[:], 
                          system.atlas_texture, system.font_system.font_atlas_texture)
    }
}