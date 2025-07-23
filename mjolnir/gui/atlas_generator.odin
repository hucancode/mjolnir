package gui

import "core:mem"
import "core:math"

// Atlas texture generation for GUI elements
// Creates a single texture with all UI elements

GUI_ATLAS_WIDTH :: 512
GUI_ATLAS_HEIGHT :: 512

// Generate the default GUI atlas texture
generate_gui_atlas :: proc(allocator := context.allocator) -> []u8 {
    atlas_size := GUI_ATLAS_WIDTH * GUI_ATLAS_HEIGHT * 4 // RGBA
    pixels := make([]u8, atlas_size, allocator)
    
    // Clear to transparent
    mem.set(raw_data(pixels), 0, atlas_size)
    
    // Helper to set pixel
    set_pixel :: proc(pixels: []u8, x, y: int, r, g, b, a: u8) {
        if x >= 0 && x < GUI_ATLAS_WIDTH && y >= 0 && y < GUI_ATLAS_HEIGHT {
            idx := (y * GUI_ATLAS_WIDTH + x) * 4
            pixels[idx + 0] = r
            pixels[idx + 1] = g
            pixels[idx + 2] = b
            pixels[idx + 3] = a
        }
    }
    
    // Helper to draw a filled rectangle
    fill_rect :: proc(pixels: []u8, x, y, w, h: int, r, g, b, a: u8) {
        for dy in 0..<h {
            for dx in 0..<w {
                set_pixel(pixels, x + dx, y + dy, r, g, b, a)
            }
        }
    }
    
    // Helper to draw a rectangle border
    draw_rect :: proc(pixels: []u8, x, y, w, h, thickness: int, r, g, b, a: u8) {
        // Top and bottom
        for dx in 0..<w {
            for t in 0..<thickness {
                set_pixel(pixels, x + dx, y + t, r, g, b, a)
                set_pixel(pixels, x + dx, y + h - 1 - t, r, g, b, a)
            }
        }
        // Left and right
        for dy in 0..<h {
            for t in 0..<thickness {
                set_pixel(pixels, x + t, y + dy, r, g, b, a)
                set_pixel(pixels, x + w - 1 - t, y + dy, r, g, b, a)
            }
        }
    }
    
    // Helper to draw rounded rectangle
    draw_rounded_rect :: proc(pixels: []u8, x, y, w, h, radius: int, r, g, b, a: u8, filled: bool) {
        if filled {
            // Fill main rectangle
            fill_rect(pixels, x + radius, y, w - 2*radius, h, r, g, b, a)
            fill_rect(pixels, x, y + radius, w, h - 2*radius, r, g, b, a)
            
            // Fill corners
            for dy in 0..<radius {
                for dx in 0..<radius {
                    dist_sq := (dx - radius) * (dx - radius) + (dy - radius) * (dy - radius)
                    if dist_sq <= radius * radius {
                        // Top-left
                        set_pixel(pixels, x + dx, y + dy, r, g, b, a)
                        // Top-right
                        set_pixel(pixels, x + w - radius + dx, y + dy, r, g, b, a)
                        // Bottom-left
                        set_pixel(pixels, x + dx, y + h - radius + dy, r, g, b, a)
                        // Bottom-right
                        set_pixel(pixels, x + w - radius + dx, y + h - radius + dy, r, g, b, a)
                    }
                }
            }
        } else {
            // Draw border only
            draw_rect(pixels, x, y + radius, w, h - 2*radius, 1, r, g, b, a)
            draw_rect(pixels, x + radius, y, w - 2*radius, h, 1, r, g, b, a)
            
            // Draw corner arcs
            for angle in 0..<90 {
                rad := f32(angle) * math.PI / 180.0
                dx := int(f32(radius) * math.cos(rad))
                dy := int(f32(radius) * math.sin(rad))
                
                // Top-left
                set_pixel(pixels, x + radius - dx, y + radius - dy, r, g, b, a)
                // Top-right
                set_pixel(pixels, x + w - radius + dx - 1, y + radius - dy, r, g, b, a)
                // Bottom-left
                set_pixel(pixels, x + radius - dx, y + h - radius + dy - 1, r, g, b, a)
                // Bottom-right
                set_pixel(pixels, x + w - radius + dx - 1, y + h - radius + dy - 1, r, g, b, a)
            }
        }
    }
    
    // Draw gradient
    draw_gradient :: proc(pixels: []u8, x, y, w, h: int, r1, g1, b1, a1, r2, g2, b2, a2: u8, vertical: bool) {
        for dy in 0..<h {
            for dx in 0..<w {
                t := f32(dy if vertical else dx) / f32(h - 1 if vertical else w - 1)
                r := u8(f32(r1) * (1 - t) + f32(r2) * t)
                g := u8(f32(g1) * (1 - t) + f32(g2) * t)
                b := u8(f32(b1) * (1 - t) + f32(b2) * t)
                a := u8(f32(a1) * (1 - t) + f32(a2) * t)
                set_pixel(pixels, x + dx, y + dy, r, g, b, a)
            }
        }
    }
    
    // Atlas layout based on ui_atlas.odin definitions
    element_size := 32
    padding := 2
    
    // Button states (row 0)
    // Normal button
    draw_rounded_rect(pixels, 0, 0, element_size, element_size, 4, 80, 80, 80, 255, true)
    draw_rounded_rect(pixels, 0, 0, element_size, element_size, 4, 100, 100, 100, 255, false)
    
    // Hover button
    draw_rounded_rect(pixels, element_size + padding, 0, element_size, element_size, 4, 100, 100, 100, 255, true)
    draw_rounded_rect(pixels, element_size + padding, 0, element_size, element_size, 4, 120, 120, 120, 255, false)
    
    // Pressed button
    draw_rounded_rect(pixels, 2 * (element_size + padding), 0, element_size, element_size, 4, 60, 60, 60, 255, true)
    draw_rounded_rect(pixels, 2 * (element_size + padding), 0, element_size, element_size, 4, 80, 80, 80, 255, false)
    
    // Disabled button
    draw_rounded_rect(pixels, 3 * (element_size + padding), 0, element_size, element_size, 4, 40, 40, 40, 128, true)
    draw_rounded_rect(pixels, 3 * (element_size + padding), 0, element_size, element_size, 4, 50, 50, 50, 128, false)
    
    // Panel elements (row 1)
    row1_y := element_size + padding
    
    // Panel background
    fill_rect(pixels, 0, row1_y, element_size, element_size, 30, 30, 30, 200)
    
    // Panel border
    draw_rect(pixels, element_size + padding, row1_y, element_size, element_size, 2, 70, 70, 70, 255)
    
    // Dropdown elements (row 2)
    row2_y := 2 * (element_size + padding)
    
    // Dropdown background
    fill_rect(pixels, 0, row2_y, element_size, element_size, 50, 50, 50, 255)
    draw_rect(pixels, 0, row2_y, element_size, element_size, 1, 80, 80, 80, 255)
    
    // Dropdown arrow down
    arrow_x := element_size + padding + element_size / 2
    arrow_y := row2_y + element_size / 2
    for i in 0..<8 {
        for j in 0..=i {
            set_pixel(pixels, arrow_x - i/2 + j, arrow_y + i - 4, 200, 200, 200, 255)
        }
    }
    
    // Dropdown arrow up
    arrow_x = 2 * (element_size + padding) + element_size / 2
    for i in 0..<8 {
        for j in 0..=i {
            set_pixel(pixels, arrow_x - i/2 + j, arrow_y - i + 4, 200, 200, 200, 255)
        }
    }
    
    // Icons (row 3) - smaller size
    row3_y := 3 * (element_size + padding)
    icon_size := 16
    
    // Close icon (X)
    for i in 0..<icon_size {
        set_pixel(pixels, i, row3_y + i, 255, 100, 100, 255)
        set_pixel(pixels, icon_size - 1 - i, row3_y + i, 255, 100, 100, 255)
    }
    
    // Minimize icon (-)
    icon_x := icon_size + padding
    fill_rect(pixels, icon_x, row3_y + icon_size/2 - 1, icon_size, 2, 200, 200, 200, 255)
    
    // Maximize icon (□)
    icon_x = 2 * (icon_size + padding)
    draw_rect(pixels, icon_x, row3_y, icon_size, icon_size, 2, 200, 200, 200, 255)
    
    // Progress bar elements (row 4)
    row4_y := 4 * (element_size + padding)
    progress_width := element_size * 3
    progress_height := element_size / 2
    
    // Progress background
    fill_rect(pixels, 0, row4_y, progress_width, progress_height, 40, 40, 40, 255)
    draw_rect(pixels, 0, row4_y, progress_width, progress_height, 1, 60, 60, 60, 255)
    
    // Progress fill
    row4_y2 := row4_y + progress_height + padding
    draw_gradient(pixels, 0, row4_y2, progress_width, progress_height, 
                  50, 150, 250, 255, 30, 100, 200, 255, false)
    
    // Input field elements (row 5)
    row5_y := 5 * (element_size + padding)
    input_width := element_size * 2
    
    // Input background
    fill_rect(pixels, 0, row5_y, input_width, element_size, 20, 20, 20, 255)
    
    // Input border
    draw_rect(pixels, 2 * element_size + padding, row5_y, input_width, element_size, 2, 100, 100, 100, 255)
    
    // Input cursor
    fill_rect(pixels, 4 * element_size + 2 * padding, row5_y, 2, element_size, 255, 255, 255, 255)
    
    // Checkbox/Radio elements (row 6)
    row6_y := 6 * (element_size + padding)
    
    // Checkbox unchecked
    draw_rect(pixels, 0, row6_y, element_size, element_size, 2, 150, 150, 150, 255)
    
    // Checkbox checked
    draw_rect(pixels, element_size + padding, row6_y, element_size, element_size, 2, 150, 150, 150, 255)
    // Draw checkmark
    for i in 0..<10 {
        set_pixel(pixels, element_size + padding + 5 + i, row6_y + 15 + i/2, 100, 255, 100, 255)
        set_pixel(pixels, element_size + padding + 15 + i, row6_y + 20 - i, 100, 255, 100, 255)
    }
    
    // Radio unchecked
    draw_circle :: proc(pixels: []u8, cx, cy, radius: int, r, g, b, a: u8, filled: bool) {
        for y in -radius..=radius {
            for x in -radius..=radius {
                dist_sq := x*x + y*y
                if filled {
                    if dist_sq <= radius*radius {
                        set_pixel(pixels, cx + x, cy + y, r, g, b, a)
                    }
                } else {
                    if dist_sq >= (radius-2)*(radius-2) && dist_sq <= radius*radius {
                        set_pixel(pixels, cx + x, cy + y, r, g, b, a)
                    }
                }
            }
        }
    }
    
    radio_x := 2 * (element_size + padding) + element_size / 2
    radio_y := row6_y + element_size / 2
    draw_circle(pixels, radio_x, radio_y, element_size/2 - 4, 150, 150, 150, 255, false)
    
    // Radio checked
    radio_x = 3 * (element_size + padding) + element_size / 2
    draw_circle(pixels, radio_x, radio_y, element_size/2 - 4, 150, 150, 150, 255, false)
    draw_circle(pixels, radio_x, radio_y, element_size/2 - 8, 100, 200, 255, 255, true)
    
    // Slider elements (row 7)
    row7_y := 7 * (element_size + padding)
    slider_width := element_size * 3
    slider_height := element_size / 2
    
    // Slider background
    fill_rect(pixels, 0, row7_y + slider_height/4, slider_width, slider_height/2, 60, 60, 60, 255)
    
    // Slider handle
    row7_y2 := row7_y + slider_height + padding
    draw_circle(pixels, element_size/4, row7_y2 + element_size/2, element_size/4, 200, 200, 200, 255, true)
    draw_circle(pixels, element_size/4, row7_y2 + element_size/2, element_size/4, 255, 255, 255, 255, false)
    
    // Scrollbar elements (row 8)
    row8_y := 8 * (element_size + padding)
    scrollbar_width := element_size / 2
    scrollbar_height := element_size * 3
    
    // Scrollbar background
    fill_rect(pixels, 0, row8_y, scrollbar_width, scrollbar_height, 40, 40, 40, 255)
    
    // Scrollbar handle
    fill_rect(pixels, scrollbar_width + padding, row8_y, scrollbar_width, element_size, 80, 80, 80, 255)
    draw_rounded_rect(pixels, scrollbar_width + padding, row8_y, scrollbar_width, element_size, 4, 100, 100, 100, 255, false)
    
    return pixels
}