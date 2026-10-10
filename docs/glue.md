---
title: Glue
---

Layer-2 modules never call each other. Moving data between them is
the application's job, and each hop is one loop over a feed the
source module publishes. Mjolnir keeps those feeds small so the glue
stays a handful of lines you can read, change or drop.

## World → render

`world.update` publishes two feeds, valid until the next update:

| Feed | Item | Render call |
|---|---|---|
| `world.removed_nodes` | node index | `render.stage_slot_removal` |
| `world.changed_nodes` | `{index, world_matrix, visible}` | `render.stage_transform` |

The engine calls the `sync` callback right after `world.update`:

```odin
sync :: proc(e: ^mjolnir.Engine) {
  for i in world.removed_nodes(&e.world) do render.stage_slot_removal(&e.render, i)
  for n in world.changed_nodes(&e.world) do render.stage_transform(&e.render, n.index, n.world_matrix, n.visible)
}
```

Filter or remap indices here if render should not mirror every node.

## Animation → render

The application owns each `animation.Animator` and keeps it next to
the node it skins. Advance it in `update`, upload its palette in
`sync`:

```odin
update :: proc(e: ^mjolnir.Engine, dt: f32) {
  anim.animator_update(&animator, rig, dt, world.world_matrix(&e.world, node))
}

sync :: proc(e: ^mjolnir.Engine) {
  // ... world → render loops ...
  render.stage_bones(&e.render, node.index, animator.palette)
}
```

The last argument of `animator_update` places the skeleton in the
world. Only world-space IK targets and procedural modifiers read it;
pass nothing when the animator uses neither. `mjolnir.load_gltf`
returns the rigs and a `skinned` list of `{node, rig}` pairs, and the
caller creates one animator per entry.

## Animation → world

**Bone sockets.** To attach a node to a bone, look the bone up once
and set the child's local matrix each tick. The child must be
parented to the skinned node:

```odin
hand := anim.find_bone(&rig.skeleton, "hand_r")
world.set_local_matrix(&e.world, sword, anim.bone_matrix(&animator, hand))
```

**Node animation.** A clip channel can drive any node. Sample it and
write the result:

```odin
anim.playback_advance(&time, &speed, &status, .LOOP, clip.duration, dt)
trs := anim.TRS_IDENTITY
anim.clip_sample_trs(&clip, 0, time, &trs)
world.set_local_matrix(&e.world, node, anim.trs_matrix(trs))
```

## Physics → world

Every body carries a `user: cont.Handle`. The `mjolnir.spawn_static`,
`spawn_dynamic` and `spawn_trigger` helpers set it to the node handle.
After stepping, copy awake body poses back:

```odin
update :: proc(e: ^mjolnir.Engine, dt: f32) {
  physics.step(&phys, dt)
  for b in physics.body_poses(&phys) do world.set_world_pose(&e.world, world.NodeHandle(b.user), b.position, b.rotation)
}
```

`set_world_pose` takes a world-space pose, so bodies on parented nodes
land in the right place.

The `physics.World` is a user value: `physics.init` it in `main`,
`physics.shutdown` it on exit. Bodies are user-owned too. Despawning
a node does not destroy its body or trigger; call
`physics.destroy_body` / `physics.destroy_trigger` alongside
`world.despawn`, or `physics.teardown` to clear everything.

## World → camera

Cameras live in render. To follow a node:

```odin
cam := render.main_camera(&e.render)
render.camera_set_transform(cam, world.world_matrix(&e.world, player))
```

## Geometry → navigation

Navigation takes plain triangles; gather them from wherever the level
comes from:

```odin
b: nav.NavGeometryBuilder
defer nav.builder_destroy(&b)
nav.append_triangles(&b, mesh.positions(ground, context.temp_allocator), ground.indices)
nav.append_triangles(&b, wall_positions, wall_indices, offset = wall_pos, is_obstacle = true)
nav.build(&navmesh, nav.geometry_view(&b))
```

To draw the result, upload `nav.debug_triangles(&navmesh)` as a
render mesh.

## UI → render

The engine run loop forwards UI draw commands and the font atlas to
render each frame:

```odin
if pixels, w, h, changed := ui.take_font_atlas(&e.ui); changed {
  render.stage_ui_font_atlas(&e.render, pixels, w, h)
}
render.stage_ui(&e.render, ui.build_commands(&e.ui))
```

## Platform → render, ui

The engine creates the Vulkan instance through render with the
extensions and loader platform reports, has platform create the
surface, then hands render the framebuffer size and DPI scale every
frame (`render.frame`). Mouse state goes to `ui.process_mouse` once
per update tick.
