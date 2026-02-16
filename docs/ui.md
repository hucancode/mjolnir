# UI Module (`mjolnir/ui`)

```odin
import "../../mjolnir/ui"

button, _ := ui.create_quad2d(&engine.ui, position = {100, 100}, size = {200, 50}, color = {255, 100, 100, 255})
label, _ := ui.create_text2d(&engine.ui, position = {100, 100}, text = "Click me!", bounds = {200, 50}, h_align = .Center, v_align = .Middle)
```

Examples: `examples/ui/main.odin`
