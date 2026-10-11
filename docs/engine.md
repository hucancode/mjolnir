---
title: Engine
---

Layer 3, optional. The `mjolnir` package holds two things:

- **A run loop** (`run`): update and render cadence, plus the optional
  update thread. It imports no layer-2 module.
- **Asset loading** (`load_gltf`): one asset fills several modules
  (world nodes, render looks, animation rigs), so it lives above them.

Everything else is the application's: it owns every module value,
brings them up, and writes the glue between them. This page shows how.

## Building an application

```odin
App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Cube") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Cube", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = render.orbit_controller()

  cube := world.spawn(&app.scene)
  render.attach(&app.renderer, cube.index, render.primitive(&app.renderer, .CUBE, .RED))

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
```

Allocate `App` with `new`: a `Platform` must not move after `init`.
The bring-up order is platform, then render, then world. Each `defer`
tears its module down in reverse.

Add modules by adding a field and their lines:

- **ui:** `ui.init` with a font in `main`, `ui.process_input` in
  `update`, `render.stage_ui(&app.renderer, ui.draw_list(&app.gui))`
  in `frame`.
- **debug UI:** `render.debug_ui_input` first in `update`, and
  `render.debug_ui(&app.renderer)` widgets in `frame` before
  `render.frame`.
- **physics, navigation, animation:** plain values in `App`, stepped
  in `update`, with the hops below.

## Wiring modules

Modules never call each other. Moving data between them is the
application's job, and each hop is one trivial loop: the source module
publishes a feed and the destination consumes it.

```odin
for x in a.feed(&a_state) do b.consume(&b_state, x)
```

Each module owns its own timing and thread safety, so the glue never
schedules or locks anything. A full `update` with every module:

```odin
update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  ui.process_input(&app.gui, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  // gameplay, reading app.input
  physics.step(&app.phys, dt)
  for b in physics.body_poses(&app.phys) do world.set_world_pose(&app.scene, world.NodeHandle(b.user), b.position, b.rotation)
  for &a, i in app.animators do anim.animator_update(&a, &app.model.rigs[app.model.skinned[i].rig], dt, world.world_matrix(&app.scene, app.model.skinned[i].node))
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  for s, i in app.model.skinned do render.stage_bones(&app.renderer, s.node.index, app.animators[i].palette)
  render.update(&app.renderer, dt)
}
```

### Input → debug UI, UI, camera

`platform.read_input` drains window events into one `input.State` per
tick. Each consumer skips a device an earlier one captured, so the
call order is the priority. Gameplay reads
`app.input.mouse_captured` / `app.input.keyboard_captured` to ignore
input a UI took.

### UI → render

Once per frame, before `render.frame`:
`render.stage_ui(&app.renderer, ui.draw_list(&app.gui))`. The draw list
carries the font atlas on frames where it changed.

### Platform → render

`render.init` takes what the window provides: instance extensions, the
proc-address loader, and `platform.create_surface` with the platform
as its argument. Every frame, `render.frame` gets the framebuffer size
and DPI scale. Neither module imports the other.


### World → render

`world.update` publishes two feeds, valid until the next update:

| Feed | Item | Render call |
|---|---|---|
| `world.removed_nodes` | node index | `render.stage_slot_removal` |
| `world.changed_nodes` | `{index, world_matrix, visible}` | `render.stage_transform` |

Run `world.update` after every write to the scene graph for the tick
(physics poses, sockets, gameplay), then the two loops.

### Animation → render

The application owns each `animation.Animator` and keeps it next to
the node it skins. Advance it, then upload its palette:

```odin
anim.animator_update(&animator, rig, dt, world.world_matrix(&app.scene, node))
render.stage_bones(&app.renderer, node.index, animator.palette)
```

The last argument of `animator_update` places the skeleton in the
world. Only world-space IK targets and procedural modifiers read it;
pass nothing when the animator uses neither. `mjolnir.load_gltf`
returns the rigs and a `skinned` list of `{node, rig}` pairs, and the
caller creates one animator per entry.

To draw a skeleton, feed `anim.bone_segments(&animator, &rig.skeleton,
root_world)` to `render.debug_segment`.

### Animation → world

**Bone sockets.** To attach a node to a bone, look the bone up once
and set the child's local matrix each tick. The child must be
parented to the skinned node:

```odin
hand := anim.find_bone(&rig.skeleton, "hand_r")
world.set_local_matrix(&app.scene, sword, anim.bone_matrix(&animator, hand))
```

**Node animation.** A clip channel can drive any node. Sample it and
write the result:

```odin
player := anim.ClipPlayer{speed = 1} // kept with the node; loops by default
// every tick
world.set_local_matrix(&app.scene, node, anim.clip_player_update(&player, &clip, dt))
```

### Physics → world

Every body carries a `user: cont.Handle`; set it to the node handle
when creating the body. After stepping, copy awake body poses back,
before `world.update`:

```odin
physics.step(&phys, dt)
for b in physics.body_poses(&phys) do world.set_world_pose(&app.scene, world.NodeHandle(b.user), b.position, b.rotation)
```

`set_world_pose` takes a world-space pose, so bodies on parented nodes
land in the right place.

The `physics.World` is a user value: `physics.init` it in `main`,
`physics.shutdown` it on exit. Bodies are user-owned too. Despawning
a node does not destroy its body; call `physics.destroy_body`
alongside `world.despawn`, or `physics.teardown` to clear everything.
The reverse happens for one case: a dynamic body that falls below
`physics.KILL_Y` is destroyed by `step` and reported in `phys.killed`.

### World → camera

Cameras live in render. To follow a node:

```odin
cam := render.main_camera(&app.renderer)
render.camera_set_transform(cam, world.world_matrix(&app.scene, player))
```

### Geometry → navigation

Navigation takes plain triangles; gather them from wherever the level
comes from:

```odin
b: bake.NavGeometryBuilder
defer bake.builder_destroy(&b)
bake.append_triangles(&b, mesh.positions(ground, context.temp_allocator), ground.indices)
bake.append_triangles(&b, wall_positions, wall_indices, offset = wall_pos, is_obstacle = true)
bake.build(&navmesh, &b)
```

An OBJ file works the same way: `mesh.load_obj(path)` returns an
`ObjMesh{positions, indices}` to append (free it with
`mesh.obj_mesh_destroy`).

To draw the result, upload `nav.debug_triangles(&navmesh)` as a
render mesh.

## Levels

To swap levels, clear both modules and set up again from `update`:

```odin
world.teardown(&app.scene)
render.teardown(&app.renderer)
render.setup(&app.renderer)
render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
// spawn the next level
```

## glTF

`load_gltf(&w, &r, path, parent = {})` returns a
`GltfScene{roots, rigs, skinned}`. It works in four steps:

1. Parses the file.
2. Has `render/gltf` (`load_meshes`) create one render mesh per glTF mesh.
3. Has `animation/gltf` (`load_rig`) create one `animation.Rig` per
   skin, with every animation as a clip.
4. Spawns one world node per glTF node under `parent` (the world root
   by default).

`skinned` pairs each skinned node with its rig. To import into a
single module, call the two loaders directly. The caller creates the
animators and frees the scene with `gltf_scene_destroy`.

## Run loop

```odin
Loop :: struct($T: typeid) {
  app:          ^T,
  should_close: proc(app: ^T) -> bool,
  update:       proc(app: ^T, dt: f32), // UPDATE_FPS
  frame:        proc(app: ^T) -> bool,  // RENDER_FPS, main thread; false on error
}

mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
```

`run` returns when one of these happens:

- `should_close` returns true.
- `FRAME_LIMIT` frames have rendered.
- `frame` fails `MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED` times in a row.

It frees `context.temp_allocator` after every frame (and after every
update tick on the update thread). Install a logger in `main` before
bringing modules up.

Build flags:

| Flag | Default | Effect |
|---|---|---|
| `RENDER_FPS` | 60 | `frame` rate cap |
| `UPDATE_FPS` | `RENDER_FPS` | `update` tick rate |
| `USE_PARALLEL_UPDATE` | false | run `update` on its own thread |
| `FRAME_LIMIT` | 0 | exit after N frames (0 = never) |

## Threading

- `update` runs on the main thread by default. With
  `-define:USE_PARALLEL_UPDATE=true` it moves to a dedicated thread.
- `frame` always runs on the main thread. Poll window events and
  build the debug UI there.
- Render's `stage_*` / `attach` calls are mutex-guarded, so `update`
  can call them while `frame` runs `render.frame`.
