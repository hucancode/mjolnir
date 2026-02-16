# Geometry Module (`mjolnir/geometry`)

```odin
import "../../mjolnir/geometry"

ground := geometry.make_quad([4]f32{0.2, 0.6, 0.2, 1.0})
sphere := geometry.make_sphere(12, 6, 0.3, [4]f32{1, 0, 0, 1})
ray := geometry.Ray{origin = ray_origin, direction = ray_dir}
```

Examples: `examples/navmesh/main.odin`, `examples/aoe/main.odin`, `examples/light/main.odin`
