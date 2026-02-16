# Animation Module (`mjolnir/animation`)

```odin
import "../../mjolnir/animation"

spline := animation.spline_create([3]f32, 10)
if animation.spline_validate(spline) {
  animation.spline_build_arc_table(&spline, 200)
  pos := animation.spline_sample_uniform(spline, s)
}
animation.spline_destroy(&spline)
```

Examples: `examples/spline/main.odin`, `examples/animation_layering/main.odin`, `examples/path_modifier/main.odin`
