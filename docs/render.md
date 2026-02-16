# Render Module (`mjolnir/render/*`)

```odin
import post_process "../../mjolnir/render/post_process"

post_process.add_crosshatch(&engine.render.post_process, {800, 600})
engine.render.visibility.stats_enabled = false
```

Examples: `examples/crosshatch/main.odin`, `examples/aoe/main.odin`
