package tests

import "core:testing"
import "core:log"
import "core:fmt"
import "core:time"
import gui "../mjolnir/gui"

// Test the core UI command generation system
@(test)
test_ui_command_types :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test UICommand_Rect
    rect_cmd := gui.UICommand_Rect{
        rect = {10, 20, 100, 50},
        color = {1.0, 0.5, 0.0, 1.0},
    }
    
    // Verify rect command fields
    testing.expect_value(t, rect_cmd.rect.x, f32(10))
    testing.expect_value(t, rect_cmd.rect.y, f32(20))
    testing.expect_value(t, rect_cmd.rect.z, f32(100)) // width
    testing.expect_value(t, rect_cmd.rect.w, f32(50))  // height
    
    // Test UICommand_Text
    text_cmd := gui.UICommand_Text{
        text = "Hello World",
        position = {50, 60},
        color = {1.0, 1.0, 1.0, 1.0},
        font_size = 16,
        font_id = 0,
    }
    
    testing.expect_value(t, text_cmd.text, "Hello World")
    testing.expect_value(t, text_cmd.font_size, f32(16))
    
    // Test UICommand_AtlasImage
    atlas_cmd := gui.UICommand_AtlasImage{
        rect = {0, 0, 32, 32},
        atlas_region = gui.UIAtlasRegion{
            uv = {0.0, 0.0, 0.125, 0.125},
        },
        color = {1.0, 1.0, 1.0, 1.0},
    }
    
    testing.expect(t, atlas_cmd.atlas_region.uv.z > atlas_cmd.atlas_region.uv.x, "Atlas region should have width")
    
    // Test UICommand_Clip
    clip_cmd := gui.UICommand_Clip{
        rect = {0, 0, 800, 600},
    }
    
    testing.expect_value(t, clip_cmd.rect.z, f32(800))
}

@(test)
test_ui_command_buffer :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create command buffer
    commands := make([dynamic]gui.UICommand, 0, 100)
    defer delete(commands)
    
    // Add various commands
    append(&commands, gui.UICommand_Rect{
        rect = {0, 0, 100, 100},
        color = {0.2, 0.2, 0.2, 1.0},
    })
    
    append(&commands, gui.UICommand_Text{
        text = "Button",
        position = {10, 40},
        color = {1.0, 1.0, 1.0, 1.0},
        font_size = 16,
        font_id = 0,
    })
    
    append(&commands, gui.UICommand_AtlasImage{
        rect = {110, 0, 32, 32},
        atlas_region = gui.UIAtlasRegion{
            uv = {0.0, 0.0, 0.0625, 0.0625},
        },
        color = {1.0, 1.0, 1.0, 1.0},
    })
    
    // Verify commands were added
    testing.expect_value(t, len(commands), 3)
    
    // Test command type checking
    rect_count := 0
    text_count := 0
    atlas_count := 0
    
    for cmd in commands {
        switch c in cmd {
        case gui.UICommand_Rect:
            rect_count += 1
        case gui.UICommand_Text:
            text_count += 1
        case gui.UICommand_AtlasImage:
            atlas_count += 1
        case gui.UICommand_Clip:
            // Not used in this test
        }
    }
    
    testing.expect_value(t, rect_count, 1)
    testing.expect_value(t, text_count, 1)
    testing.expect_value(t, atlas_count, 1)
}

@(test)
test_widget_base_functionality :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create a basic widget
    widget := gui.Widget{}
    widget.id = 1
    widget.parent = nil
    widget.enabled = true
    widget.visible = true
    widget.dirty = true
    widget.position = {0, 0}
    widget.size = {0, 0}
    widget.z_order = 0
    widget.children = make([dynamic]^gui.Widget, 0, 4)
    
    // Test initial state
    testing.expect(t, widget.enabled, "Widget should be enabled by default")
    testing.expect(t, widget.visible, "Widget should be visible by default")
    testing.expect(t, widget.dirty, "Widget should be dirty by default")
    testing.expect_value(t, widget.id, u32(1))
    
    // Test position and size
    widget.position = {100, 200}
    widget.size = {300, 150}
    
    // Test contains point
    testing.expect(t, gui.widget_contains_point(&widget, {150, 250}), "Point should be inside widget")
    testing.expect(t, !gui.widget_contains_point(&widget, {50, 100}), "Point should be outside widget")
    testing.expect(t, !gui.widget_contains_point(&widget, {450, 250}), "Point should be outside widget")
    
    // Test dirty flag
    widget.dirty = false
    widget.dirty = true
    testing.expect(t, widget.dirty, "Widget should be dirty after marking")
    
    // Test enable/disable
    gui.widget_set_enabled(&widget, false)
    testing.expect(t, !widget.enabled, "Widget should be disabled")
    
    gui.widget_set_enabled(&widget, true) 
    testing.expect(t, widget.enabled, "Widget should be enabled")
    
    // Test visibility
    gui.widget_set_visible(&widget, false)
    testing.expect(t, !widget.visible, "Widget should be hidden")
    
    gui.widget_set_visible(&widget, true)
    testing.expect(t, widget.visible, "Widget should be visible")
}

@(test)
test_widget_hierarchy :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create parent widget
    parent := gui.Widget{}
    parent.id = 1
    parent.parent = nil
    parent.enabled = true
    parent.visible = true
    parent.dirty = true
    parent.children = make([dynamic]^gui.Widget, 0, 4)
    parent.position = {0, 0}
    parent.size = {500, 400}
    
    // Create child widgets
    child1 := gui.Widget{}
    child1.id = 2
    child1.parent = &parent
    child1.enabled = true
    child1.visible = true
    child1.dirty = true
    child1.children = make([dynamic]^gui.Widget, 0, 4)
    append(&parent.children, &child1)
    
    child2 := gui.Widget{}
    child2.id = 3
    child2.parent = &parent
    child2.enabled = true
    child2.visible = true
    child2.dirty = true
    child2.children = make([dynamic]^gui.Widget, 0, 4)
    append(&parent.children, &child2)
    
    // Verify parent-child relationships
    testing.expect_value(t, len(parent.children), 2)
    testing.expect_value(t, child1.parent, &parent)
    testing.expect_value(t, child2.parent, &parent)
    
    // Test child ordering
    testing.expect_value(t, parent.children[0], &child1)
    testing.expect_value(t, parent.children[1], &child2)
    
    // Test removing child
    gui.widget_remove_child(&parent, &child1)
    testing.expect_value(t, len(parent.children), 1)
    testing.expect_value(t, parent.children[0], &child2)
    testing.expect(t, child1.parent == nil, "Removed child should have no parent")
    
    // Clean up
    delete(parent.children)
    delete(child1.children)
    delete(child2.children)
}

@(test)
test_input_state :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    state := gui.InputState{}
    gui.input_state_init(&state)
    
    // Test mouse position
    gui.input_state_update_mouse_pos(&state, 100, 200)
    testing.expect_value(t, state.mouse_pos, [2]f32{100, 200})
    
    // Test mouse buttons
    gui.input_state_update_mouse_button(&state, .Left, true)
    testing.expect(t, state.mouse_buttons[0], "Left mouse button should be pressed")
    
    gui.input_state_update_mouse_button(&state, .Left, false)
    testing.expect(t, !state.mouse_buttons[0], "Left mouse button should be released")
    
    // Test keyboard
    gui.input_state_update_key(&state, 65, true) // 'A' key
    testing.expect(t, state.keys[65], "A key should be pressed")
    
    // Test modifiers
    gui.input_state_update_modifiers(&state, 1) // Shift
    testing.expect(t, .Shift in state.key_modifiers, "Shift should be active")
}

@(test)
test_atlas_regions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test default atlas layout
    regions := gui.create_default_atlas_layout()
    
    // Verify some standard regions exist
    // Check that regions have valid UV coordinates
    testing.expect(t, regions.button_normal.uv.z > regions.button_normal.uv.x, "Button normal should have width")
    testing.expect(t, regions.button_normal.uv.w > regions.button_normal.uv.y, "Button normal should have height")
    testing.expect(t, regions.button_hover.uv.z > regions.button_hover.uv.x, "Button hover should have width")
    testing.expect(t, regions.button_pressed.uv.z > regions.button_pressed.uv.x, "Button pressed should have width")
}

@(test)
test_font_bitmap :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test font atlas generation
    font_pixels := gui.generate_font_atlas()
    defer delete(font_pixels)
    
    expected_size := gui.FONT_ATLAS_WIDTH * gui.FONT_ATLAS_HEIGHT
    testing.expect_value(t, len(font_pixels), int(expected_size))
    
    // Test character UV calculation
    char_uv := gui.get_char_uv('A')
    testing.expect(t, char_uv.x >= 0 && char_uv.x <= 1, "U coord should be normalized")
    testing.expect(t, char_uv.y >= 0 && char_uv.y <= 1, "V coord should be normalized")
    testing.expect(t, char_uv.z > char_uv.x, "UV width should be positive")
    testing.expect(t, char_uv.w > char_uv.y, "UV height should be positive")
    
    // Test text measurement
    text_size := gui.measure_text("Hello", 2.0)
    testing.expect(t, text_size.x > 0, "Text should have width")
    testing.expect(t, text_size.y > 0, "Text should have height")
    testing.expect_value(t, text_size.x, f32(5 * gui.FONT_CHAR_WIDTH * 2)) // 5 chars * width * scale
}

// Test simulated button command generation
@(test)
test_simulated_button_commands :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    commands := make([dynamic]gui.UICommand, 0, 10)
    defer delete(commands)
    
    // Simulate what a button would generate
    button_pos := [2]f32{100, 50}
    button_size := [2]f32{120, 40}
    button_text := "Click Me"
    
    // Background rectangle
    append(&commands, gui.UICommand_Rect{
        rect = {button_pos.x, button_pos.y, button_size.x, button_size.y},
        color = {0.3, 0.3, 0.3, 1.0},
    })
    
    // Border (top)
    append(&commands, gui.UICommand_Rect{
        rect = {button_pos.x, button_pos.y, button_size.x, 2},
        color = {0.5, 0.5, 0.5, 1.0},
    })
    
    // Text
    text_size := gui.measure_text(button_text, 1.0)
    text_pos := [2]f32{
        button_pos.x + (button_size.x - text_size.x) / 2,
        button_pos.y + (button_size.y - text_size.y) / 2,
    }
    
    append(&commands, gui.UICommand_Text{
        text = button_text,
        position = text_pos,
        color = {1.0, 1.0, 1.0, 1.0},
        font_size = 16,
        font_id = 0,
    })
    
    // Verify generated commands
    testing.expect_value(t, len(commands), 3)
    
    // Check first command is background rect
    if rect_cmd, ok := commands[0].(gui.UICommand_Rect); ok {
        testing.expect_value(t, rect_cmd.rect.x, button_pos.x)
        testing.expect_value(t, rect_cmd.rect.y, button_pos.y)
        testing.expect_value(t, rect_cmd.rect.z, button_size.x)
        testing.expect_value(t, rect_cmd.rect.w, button_size.y)
    } else {
        testing.fail(t)
    }
    
    // Check text command
    if text_cmd, ok := commands[2].(gui.UICommand_Text); ok {
        testing.expect_value(t, text_cmd.text, button_text)
        testing.expect(t, text_cmd.position.x >= button_pos.x, "Text should be inside button")
        testing.expect(t, text_cmd.position.y >= button_pos.y, "Text should be inside button")
    } else {
        testing.fail(t)
    }
}

// Test complex UI scene command generation
@(test)
test_complex_ui_scene :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    commands := make([dynamic]gui.UICommand, 0, 100)
    defer delete(commands)
    
    // Simulate a panel with multiple controls
    panel_pos := [2]f32{10, 10}
    panel_size := [2]f32{400, 300}
    
    // Panel background
    append(&commands, gui.UICommand_Rect{
        rect = {panel_pos.x, panel_pos.y, panel_size.x, panel_size.y},
        color = {0.15, 0.15, 0.15, 1.0},
    })
    
    // Panel title bar
    append(&commands, gui.UICommand_Rect{
        rect = {panel_pos.x, panel_pos.y, panel_size.x, 30},
        color = {0.2, 0.2, 0.2, 1.0},
    })
    
    // Panel title text
    append(&commands, gui.UICommand_Text{
        text = "Settings",
        position = {panel_pos.x + 10, panel_pos.y + 7},
        color = {1.0, 1.0, 1.0, 1.0},
        font_size = 16,
        font_id = 0,
    })
    
    // Simulate controls inside panel
    control_y := panel_pos.y + 50
    
    // Label
    append(&commands, gui.UICommand_Text{
        text = "Volume:",
        position = {panel_pos.x + 20, control_y},
        color = {0.8, 0.8, 0.8, 1.0},
        font_size = 14,
        font_id = 0,
    })
    
    // Slider track
    slider_x := panel_pos.x + 100
    append(&commands, gui.UICommand_Rect{
        rect = {slider_x, control_y + 5, 200, 4},
        color = {0.2, 0.2, 0.2, 1.0},
    })
    
    // Slider filled portion (50%)
    append(&commands, gui.UICommand_Rect{
        rect = {slider_x, control_y + 5, 100, 4},
        color = {0.3, 0.5, 0.8, 1.0},
    })
    
    // Slider handle
    append(&commands, gui.UICommand_Rect{
        rect = {slider_x + 100 - 8, control_y - 3, 16, 16},
        color = {0.8, 0.8, 0.8, 1.0},
    })
    
    // Checkbox
    control_y += 40
    append(&commands, gui.UICommand_Rect{
        rect = {panel_pos.x + 20, control_y, 20, 20},
        color = {0.1, 0.1, 0.1, 1.0},
    })
    
    // Checkbox label
    append(&commands, gui.UICommand_Text{
        text = "Enable Sound",
        position = {panel_pos.x + 50, control_y + 2},
        color = {1.0, 1.0, 1.0, 1.0},
        font_size = 14,
        font_id = 0,
    })
    
    // Button
    control_y += 40
    button_width: f32 = 100
    button_height: f32 = 30
    
    append(&commands, gui.UICommand_Rect{
        rect = {panel_pos.x + 20, control_y, button_width, button_height},
        color = {0.3, 0.3, 0.3, 1.0},
    })
    
    append(&commands, gui.UICommand_Text{
        text = "Apply",
        position = {panel_pos.x + 20 + 30, control_y + 8},
        color = {1.0, 1.0, 1.0, 1.0},
        font_size = 14,
        font_id = 0,
    })
    
    // Verify we generated a complex scene
    testing.expect(t, len(commands) >= 10, "Complex scene should have many commands")
    
    // Count command types
    rect_count := 0
    text_count := 0
    
    for cmd in commands {
        switch c in cmd {
        case gui.UICommand_Rect:
            rect_count += 1
        case gui.UICommand_Text:
            text_count += 1
        case gui.UICommand_AtlasImage:
        case gui.UICommand_Clip:
        }
    }
    
    testing.expect(t, rect_count >= 7, "Should have multiple rectangles")
    testing.expect(t, text_count >= 4, "Should have multiple text elements")
}