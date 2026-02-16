# Engine Module (`mjolnir`)

```odin
import "../../mjolnir"
import "../../mjolnir/world"

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
    world.main_camera_look_at(&engine.world, engine.world.main_camera, {3, 2, 3}, {0, 0, 0})
  }
  mjolnir.run(engine, 800, 600, "Cube")
}
```

Examples: `examples/cube/main.odin`, `examples/material/main.odin`, `examples/gltf_static/main.odin`
