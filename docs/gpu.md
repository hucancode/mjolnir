# GPU Module (`mjolnir/gpu`)

```odin
import "../../mjolnir/gpu"

tex, result := gpu.create_texture_2d_from_path(
  &engine.gctx,
  &engine.render.texture_manager,
  "assets/gold-star.png",
)
```

Examples: `examples/ui/main.odin`, `examples/ik/main.odin`
