package widgets

import ".."

PanelWidget :: struct {
    using base: gui.Widget,
    background_color: [4]f32,
    border_color: [4]f32,
    border_width: f32,
    use_atlas_background: bool,
    layout_type: gui.LayoutType,
}

panel_vtable := gui.WidgetVTable{
    generate_commands = panel_generate_commands,
    handle_input = panel_handle_input,
    update = panel_update,
    destroy = panel_destroy,
}

create_panel :: proc(system: ^gui.GUISystem, position: [2]f32, size: [2]f32) -> ^PanelWidget {
    panel := new(PanelWidget)
    gui.widget_init(&panel.base, &panel_vtable, panel)
    
    panel.position = position
    panel.size = size
    panel.background_color = {0.2, 0.2, 0.2, 0.8}
    panel.border_color = {0.5, 0.5, 0.5, 1.0}
    panel.border_width = 0
    panel.use_atlas_background = false
    panel.layout_type = .None
    
    gui.gui_system_add_widget(system, &panel.base)
    
    return panel
}

panel_set_background_color :: proc(panel: ^PanelWidget, color: [4]f32) {
    panel.background_color = color
    panel.dirty = true
}

panel_set_border :: proc(panel: ^PanelWidget, color: [4]f32, width: f32) {
    panel.border_color = color
    panel.border_width = width
    panel.dirty = true
}

panel_set_use_atlas_background :: proc(panel: ^PanelWidget, use_atlas: bool) {
    panel.use_atlas_background = use_atlas
    panel.dirty = true
}

panel_set_layout :: proc(panel: ^PanelWidget, layout_type: gui.LayoutType) {
    panel.layout_type = layout_type
    panel_update_layout(panel)
}

panel_update_layout :: proc(panel: ^PanelWidget) {
    if len(panel.children) == 0 do return
    
    padding := f32(5)
    spacing := f32(5)
    
    switch panel.layout_type {
    case .None:
        return
        
    case .Horizontal:
        x := padding
        y := padding
        for child in panel.children {
            gui.widget_set_position(child, x, y)
            x += child.size.x + spacing
        }
        
    case .Vertical:
        x := padding
        y := padding
        for child in panel.children {
            gui.widget_set_position(child, x, y)
            y += child.size.y + spacing
        }
        
    case .Grid:
        cols := 3
        x := padding
        y := padding
        col := 0
        for child in panel.children {
            gui.widget_set_position(child, x, y)
            col += 1
            if col >= cols {
                col = 0
                x = padding
                y += child.size.y + spacing
            } else {
                x += child.size.x + spacing
            }
        }
    }
}

panel_generate_commands :: proc(widget: ^gui.Widget, commands: ^[dynamic]gui.UICommand) {
    panel := cast(^PanelWidget)widget.data
    
    if panel.use_atlas_background {
        default_atlas := gui.create_default_atlas_layout()
        cmd := gui.UICommand_AtlasImage{
            rect = {widget.position.x, widget.position.y, widget.size.x, widget.size.y},
            atlas_region = default_atlas.panel_bg,
            color = panel.background_color,
        }
        append(commands, cmd)
    } else {
        cmd := gui.UICommand_Rect{
            rect = {widget.position.x, widget.position.y, widget.size.x, widget.size.y},
            color = panel.background_color,
        }
        append(commands, cmd)
    }
    
    if panel.border_width > 0 {
        cmd_top := gui.UICommand_Rect{
            rect = {widget.position.x, widget.position.y, widget.size.x, panel.border_width},
            color = panel.border_color,
        }
        append(commands, cmd_top)
        
        cmd_bottom := gui.UICommand_Rect{
            rect = {widget.position.x, widget.position.y + widget.size.y - panel.border_width, widget.size.x, panel.border_width},
            color = panel.border_color,
        }
        append(commands, cmd_bottom)
        
        cmd_left := gui.UICommand_Rect{
            rect = {widget.position.x, widget.position.y, panel.border_width, widget.size.y},
            color = panel.border_color,
        }
        append(commands, cmd_left)
        
        cmd_right := gui.UICommand_Rect{
            rect = {widget.position.x + widget.size.x - panel.border_width, widget.position.y, panel.border_width, widget.size.y},
            color = panel.border_color,
        }
        append(commands, cmd_right)
    }
}

panel_handle_input :: proc(widget: ^gui.Widget, event: gui.InputEvent) -> bool {
    return false
}

panel_update :: proc(widget: ^gui.Widget, dt: f32) {
}

panel_destroy :: proc(widget: ^gui.Widget) {
}