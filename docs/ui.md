# UI Module (`mjolnir/ui`)

The UI module provides 2D elements for HUD, menus, and overlays with event handling.

## Creating UI Elements

### Quads (Rectangles)

```odin
import "../../mjolnir/ui"

// Simple colored quad
button, ok := ui.create_quad2d(
  &engine.ui,
  position = {100, 100},
  size = {200, 50},
  color = {255, 100, 100, 255}, // RGBA
  z_order = 0,
)

// Textured quad
image_quad, ok := ui.create_quad2d(
  &engine.ui,
  position = {350, 300},
  size = {128, 128},
  texture = texture_handle,
  z_order = 1,
)

// Background quad (behind others)
bg, ok := ui.create_quad2d(
  &engine.ui,
  position = {0, 0},
  size = {800, 600},
  color = {40, 40, 60, 200}, // Semi-transparent
  z_order = -1,
)
```

### Text

```odin
// Simple text
label, ok := ui.create_text2d(
  &engine.ui,
  position = {100, 180},
  text = "Hello World",
  font_size = 20,
  color = {255, 255, 255, 255},
  z_order = 1,
)

// Text with alignment
centered_label, ok := ui.create_text2d(
  &engine.ui,
  position = {100, 100},
  text = "Click me!",
  font_size = 20,
  color = {255, 255, 255, 255},
  z_order = 2,
  bounds = {200, 50}, // Bounding box
  h_align = .Center,  // .Left, .Center, .Right
  v_align = .Middle,  // .Top, .Middle, .Bottom
)
```

### Custom Meshes

For complex shapes, create custom 2D meshes:

```odin
import cmd "../../mjolnir/gpu/ui"

// Define vertices
vertices := []cmd.Vertex2D{
  {pos = {0, 0}, uv = {0, 0}, color = {255, 0, 0, 255}},
  {pos = {100, 0}, uv = {1, 0}, color = {0, 255, 0, 255}},
  {pos = {50, 100}, uv = {0.5, 1}, color = {0, 0, 255, 255}},
}

indices := []u32{0, 1, 2}

star, ok := ui.create_mesh2d(
  &engine.ui,
  position = {400, 300},
  vertices = vertices,
  indices = indices,
  z_order = 1,
)
```

## Event Handling

### Adding Event Handlers

```odin
// Get quad widget
if quad := ui.get_quad2d(&engine.ui, button); quad != nil {
  handlers := ui.EventHandlers{
    on_mouse_down = proc(event: ui.MouseEvent) {
      log.info("Button clicked!")
      // Get engine from user data
      engine := cast(^mjolnir.Engine)event.user_data
      if engine == nil do return
      
      // Modify the widget
      if quad := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); quad != nil {
        quad.color = {100, 255, 100, 255} // Change to green
      }
    },
    
    on_mouse_up = proc(event: ui.MouseEvent) {
      log.info("Button released!")
      engine := cast(^mjolnir.Engine)event.user_data
      if engine == nil do return
      if quad := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); quad != nil {
        quad.color = {255, 150, 100, 255} // Change to orange
      }
    },
    
    on_hover_in = proc(event: ui.MouseEvent) {
      log.info("Hovering over button")
      engine := cast(^mjolnir.Engine)event.user_data
      if engine == nil do return
      if quad := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); quad != nil {
        quad.color = {255, 150, 100, 255} // Hover color
      }
    },
    
    on_hover_out = proc(event: ui.MouseEvent) {
      log.info("No longer hovering")
      engine := cast(^mjolnir.Engine)event.user_data
      if engine == nil do return
      if quad := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); quad != nil {
        quad.color = {255, 100, 100, 255} // Reset color
      }
    },
  }
  
  widget := cast(^ui.Widget)quad
  ui.set_event_handler(widget, handlers)
  ui.set_user_data(widget, engine)
}
```

### Event Types

Available events:
- `on_mouse_down`: Mouse button pressed on widget
- `on_mouse_up`: Mouse button released on widget
- `on_hover_in`: Mouse enters widget bounds
- `on_hover_out`: Mouse leaves widget bounds

## Modifying UI Elements

```odin
// Get and modify quad
if quad := ui.get_quad2d(&engine.ui, button); quad != nil {
  quad.position = {150, 150}
  quad.size = {250, 60}
  quad.color = {100, 200, 100, 255}
}

// Get and modify text
if text := ui.get_text2d(&engine.ui, label); text != nil {
  text.text = "Updated Text"
  text.color = {255, 0, 0, 255}
}
```

## Z-Ordering

Control layering with z_order (higher values render on top):

```odin
// Background
bg := ui.create_quad2d(&engine.ui, z_order = -1, ...)

// Middle layer
content := ui.create_quad2d(&engine.ui, z_order = 0, ...)

// Foreground
overlay := ui.create_quad2d(&engine.ui, z_order = 1, ...)
```

## Loading Textures for UI

```odin
import "../../mjolnir/gpu"

// Load image texture
texture, ok := gpu.create_texture_2d_from_path(
  &engine.gctx,
  &engine.render.texture_manager,
  "assets/icon.png",
)

if ok == .SUCCESS {
  // Use texture in quad
  icon, _ := ui.create_quad2d(
    &engine.ui,
    position = {300, 300},
    size = {64, 64},
    texture = texture,
  )
}
```

## Common Patterns

### Button with Label

```odin
// Create button background
button, _ := ui.create_quad2d(
  &engine.ui,
  position = {100, 100},
  size = {200, 50},
  color = {255, 100, 100, 255},
  z_order = 0,
)

// Add label centered on button
label, _ := ui.create_text2d(
  &engine.ui,
  position = {100, 100}, // Same as button
  text = "Click me!",
  font_size = 20,
  color = {255, 255, 255, 255},
  z_order = 1, // Above button
  bounds = {200, 50}, // Same as button size
  h_align = .Center,
  v_align = .Middle,
)
```

### Panel with Content

```odin
// Create panel background
panel, _ := ui.create_quad2d(
  &engine.ui,
  position = {50, 50},
  size = {700, 200},
  color = {40, 40, 60, 200},
  z_order = -1,
)

// Add content on top
content, _ := ui.create_text2d(
  &engine.ui,
  position = {60, 60},
  text = "Panel Content",
  z_order = 0,
)
```

### Image Display

```odin
// Load texture
texture, ok := gpu.create_texture_2d_from_path(
  &engine.gctx,
  &engine.render.texture_manager,
  "assets/image.png",
)

// Display as quad
if ok == .SUCCESS {
  image, _ := ui.create_quad2d(
    &engine.ui,
    position = {350, 300},
    size = {128, 128},
    texture = texture,
    z_order = 1,
  )
  
  // Add label below
  label, _ := ui.create_text2d(
    &engine.ui,
    position = {300, 440},
    text = "Image Caption",
    font_size = 20,
    color = {255, 255, 255, 255},
    z_order = 1,
  )
}
```
