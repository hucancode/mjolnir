---
title: Glue
---

Modules never call each other, and the engine provides no glue.
Moving data between modules is the application's job, and each hop is
one trivial loop: the source module publishes a feed, the destination
consumes it.

```odin
for x in a.feed(&a_state) do b.consume(&b_state, x)
```

Each module owns its own timing and thread safety, so the glue never
has to schedule or lock anything. Mjolnir keeps the feeds small so the
glue stays a handful of lines you can read, change or drop. With the
layer-3 run loop all of it lives in the `update` callback:

```odin
update :: proc(e: ^mjolnir.Engine, dt: f32) {
  // gameplay, reading e.input
  physics.step(&phys, dt)
  for b in physics.body_poses(&phys) do world.set_world_pose(&e.world, world.NodeHandle(b.user), b.position, b.rotation)
  for &a, i in animators do anim.animator_update(&a, &scene.rigs[scene.skinned[i].rig], dt, world.world_matrix(&e.world, scene.skinned[i].node))
  world.update(&e.world)
  for i in world.removed_nodes(&e.world) do render.stage_slot_removal(&e.render, i)
  for n in world.changed_nodes(&e.world) do render.stage_transform(&e.render, n.index, n.world_matrix, n.visible)
  for s, i in scene.skinned do render.stage_bones(&e.render, s.node.index, animators[i].palette)
}
```

Drop the lines for modules you don't use. Without the world → render
lines nothing moves on screen.

## World → render

`world.update` publishes two feeds, valid until the next update:

| Feed | Item | Render call |
|---|---|---|
| `world.removed_nodes` | node index | `render.stage_slot_removal` |
| `world.changed_nodes` | `{index, world_matrix, visible}` | `render.stage_transform` |

Run `world.update` after every write to the scene graph for the tick
(physics poses, sockets, gameplay), then the two loops.

## Animation → render

The application owns each `animation.Animator` and keeps it next to
the node it skins. Advance it, then upload its palette:

```odin
anim.animator_update(&animator, rig, dt, world.world_matrix(&e.world, node))
render.stage_bones(&e.render, node.index, animator.palette)
```

The last argument of `animator_update` places the skeleton in the
world. Only world-space IK targets and procedural modifiers read it;
pass nothing when the animator uses neither. `mjolnir.load_gltf`
returns the rigs and a `skinned` list of `{node, rig}` pairs, and the
caller creates one animator per entry.

To draw a skeleton, feed `anim.bone_segments(&animator, &rig.skeleton,
root_world)` to `render.debug_segment`.

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

Every body carries a `user: cont.Handle`; set it to the node handle
when creating the body. After stepping, copy awake body poses back,
before `world.update`:

```odin
physics.step(&phys, dt)
for b in physics.body_poses(&phys) do world.set_world_pose(&e.world, world.NodeHandle(b.user), b.position, b.rotation)
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
b: bake.NavGeometryBuilder
defer bake.builder_destroy(&b)
bake.append_triangles(&b, mesh.positions(ground, context.temp_allocator), ground.indices)
bake.append_triangles(&b, wall_positions, wall_indices, offset = wall_pos, is_obstacle = true)
bake.build(&navmesh, bake.geometry_view(&b))
```

An OBJ file works the same way: `mesh.load_obj(path)` returns an
`ObjMesh{positions, indices}` to append (free it with
`mesh.obj_mesh_destroy`).

To draw the result, upload `nav.debug_triangles(&navmesh)` as a
render mesh.

## Input → UI, camera

Input arrives as an `input.State` snapshot. The layer-3 run loop
takes one per update tick and hands it to both UIs and the camera
controller before the `update` callback:

```odin
input.new_frame(&e.input, &e.platform.input)
render.debug_ui_input(&e.render, &e.input)
if !render.debug_ui_wants_mouse(&e.render) do ui.process_input(&e.ui, &e.input)
render.camera_controller_update(&e.camera_controller, cam, &e.input, dt, mouse_captured, keyboard_captured)
```

## UI → render

The run loop forwards UI draw commands and the font atlas to render
each frame:

```odin
if pixels, w, h, changed := ui.take_font_atlas(&e.ui); changed {
  render.stage_ui_font_atlas(&e.render, pixels, w, h)
}
render.stage_ui(&e.render, ui.build_commands(&e.ui))
```

## Platform → render

The engine creates the Vulkan instance through render with the
extensions and loader platform reports, has platform create the
surface, then hands render the framebuffer size and DPI scale every
frame (`render.frame`).
