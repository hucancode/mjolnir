# World Module (`mjolnir/world`)

```odin
import "../../mjolnir/world"

mesh := world.get_builtin_mesh(&engine.world, .CUBE)
mat := world.get_builtin_material(&engine.world, .GRAY)
node := world.spawn(&engine.world, {0, 0, 0}, world.MeshAttachment{handle = mesh, material = mat}) or_else {}
world.scale(&engine.world, node, 2.0)
```

Examples: `examples/light/main.odin`, `examples/shadow/main.odin`, `examples/gltf_animation/main.odin`
