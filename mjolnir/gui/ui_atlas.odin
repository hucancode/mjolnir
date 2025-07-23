package gui

UIAtlasRegions :: struct {
    button_normal: UIAtlasRegion,
    button_hover: UIAtlasRegion,
    button_pressed: UIAtlasRegion,
    button_disabled: UIAtlasRegion,
    panel_bg: UIAtlasRegion,
    panel_border: UIAtlasRegion,
    dropdown_bg: UIAtlasRegion,
    dropdown_arrow: UIAtlasRegion,
    dropdown_arrow_up: UIAtlasRegion,
    icon_close: UIAtlasRegion,
    icon_minimize: UIAtlasRegion,
    icon_maximize: UIAtlasRegion,
    progress_bg: UIAtlasRegion,
    progress_fill: UIAtlasRegion,
    input_bg: UIAtlasRegion,
    input_border: UIAtlasRegion,
    input_cursor: UIAtlasRegion,
    checkbox_unchecked: UIAtlasRegion,
    checkbox_checked: UIAtlasRegion,
    radio_unchecked: UIAtlasRegion,
    radio_checked: UIAtlasRegion,
    slider_bg: UIAtlasRegion,
    slider_handle: UIAtlasRegion,
    scrollbar_bg: UIAtlasRegion,
    scrollbar_handle: UIAtlasRegion,
}

create_default_atlas_layout :: proc() -> UIAtlasRegions {
    atlas_size := f32(512)
    element_size := f32(32)
    padding := f32(2)
    
    make_region :: proc(x, y, w, h, atlas_size: f32) -> UIAtlasRegion {
        return UIAtlasRegion{
            uv = {x / atlas_size, y / atlas_size, (x + w) / atlas_size, (y + h) / atlas_size},
        }
    }
    
    regions: UIAtlasRegions
    row := f32(0)
    col := f32(0)
    
    regions.button_normal = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.button_hover = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.button_pressed = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.button_disabled = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    
    row = 1
    col = 0
    regions.panel_bg = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.panel_border = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    
    row = 2
    col = 0
    regions.dropdown_bg = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.dropdown_arrow = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.dropdown_arrow_up = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    
    row = 3
    col = 0
    icon_size := f32(16)
    regions.icon_close = make_region(col * (icon_size + padding), row * (element_size + padding), icon_size, icon_size, atlas_size)
    col += 1
    regions.icon_minimize = make_region(col * (icon_size + padding), row * (element_size + padding), icon_size, icon_size, atlas_size)
    col += 1
    regions.icon_maximize = make_region(col * (icon_size + padding), row * (element_size + padding), icon_size, icon_size, atlas_size)
    
    row = 4
    col = 0
    regions.progress_bg = make_region(col * (element_size + padding), row * (element_size + padding), element_size * 3, element_size / 2, atlas_size)
    row += 0.5
    regions.progress_fill = make_region(col * (element_size + padding), row * (element_size + padding), element_size * 3, element_size / 2, atlas_size)
    
    row = 5
    col = 0
    regions.input_bg = make_region(col * (element_size + padding), row * (element_size + padding), element_size * 2, element_size, atlas_size)
    col += 2
    regions.input_border = make_region(col * (element_size + padding), row * (element_size + padding), element_size * 2, element_size, atlas_size)
    col += 2
    regions.input_cursor = make_region(col * (element_size + padding), row * (element_size + padding), 2, element_size, atlas_size)
    
    row = 6
    col = 0
    regions.checkbox_unchecked = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.checkbox_checked = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.radio_unchecked = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    col += 1
    regions.radio_checked = make_region(col * (element_size + padding), row * (element_size + padding), element_size, element_size, atlas_size)
    
    row = 7
    col = 0
    regions.slider_bg = make_region(col * (element_size + padding), row * (element_size + padding), element_size * 3, element_size / 2, atlas_size)
    row += 0.5
    regions.slider_handle = make_region(col * (element_size + padding), row * (element_size + padding), element_size / 2, element_size, atlas_size)
    
    row = 8
    col = 0
    regions.scrollbar_bg = make_region(col * (element_size + padding), row * (element_size + padding), element_size / 2, element_size * 3, atlas_size)
    col += 0.5
    regions.scrollbar_handle = make_region(col * (element_size + padding), row * (element_size + padding), element_size / 2, element_size, atlas_size)
    
    return regions
}