# Physics Module (`mjolnir/physics`)

```odin
import "../../mjolnir/physics"

physics_world: physics.World
physics.init(&physics_world, {0, -10, 0})
_ = physics.create_dynamic_body_box(&physics_world, {0.5, 0.5, 0.5}, {0, 3, 0}, {}, 2.0)
physics.step(&physics_world, delta_time)
world.sync_all_physics_to_world(&engine.world, &physics_world)
```

Examples: `examples/jump/main.odin`, `examples/physics/main.odin`, `examples/aoe/main.odin`
