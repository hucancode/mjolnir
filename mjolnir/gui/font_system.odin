package gui

import "../gpu"
import vk "vendor:vulkan"
import "core:log"

FontSystem :: struct {
    font_atlas_texture: ^gpu.ImageBuffer,
    atlas_width: u32,
    atlas_height: u32,
    initialized: bool,
}

font_system_init :: proc(fs: ^FontSystem, gpu_context: ^gpu.GPUContext, font_texture: ^gpu.ImageBuffer) -> bool {
    fs.atlas_width = FONT_ATLAS_WIDTH
    fs.atlas_height = FONT_ATLAS_HEIGHT
    fs.initialized = false
    
    // Store provided font texture
    fs.font_atlas_texture = font_texture
    if fs.font_atlas_texture == nil {
        log.error("Font atlas texture is nil")
        return false
    }
    fs.initialized = true
    
    return true
}

font_system_destroy :: proc(fs: ^FontSystem) {
    fs.initialized = false
    // Texture cleanup handled by resource warehouse
}

// Simplified font API - just uses the one bitmap font
font_system_add_font :: proc(fs: ^FontSystem, name: string, data: []u8) -> u32 {
    // For now, ignore font data and always use default bitmap font
    return 0 // Default font ID
}

font_system_text_bounds :: proc(fs: ^FontSystem, text: string, font_id: u32, font_size: f32) -> [4]f32 {
    size := measure_text(text, font_size / f32(FONT_CHAR_HEIGHT))
    return {0, 0, size.x, size.y}
}

font_system_update_texture :: proc(fs: ^FontSystem) {
    // Nothing to update for static bitmap font
}

