# Cookbook

Recipes for the most common things you'll do with Mjolnir. Each recipe gives:

- **Goal** — what you'll achieve
- **Modules** — which packages you import
- **Code** — drop-in compilable snippet
- **Notes** — non-obvious gotchas

All recipes assume you already have `context.logger` and have allocated an
`^mjolnir.Engine`. Layer references match [`architecture.md`](architecture.html).

> ZEN.md rule 5: avoid wrappers. Recipes call the layer-2 procs directly
> (`world.*`, `physics.*`, `nav.*`, `ui.*`) — there is no engine façade.

---

## Index

1. [Hello cube](#1-hello-cube)
2. [Move and rotate a node](#2-move-and-rotate-a-node)
3. [Spawn a primitive grid](#3-spawn-a-primitive-grid)
4. [Add lights and shadows](#4-add-lights-and-shadows)
5. [Load a glTF model](#5-load-a-gltf-model)
6. [Play a skeletal animation](#6-play-a-skeletal-animation)
7. [Blend two animations on layers](#7-blend-two-animations-on-layers)
8. [Add IK head tracking](#8-add-ik-head-tracking)
9. [Procedural tail / spider legs](#9-procedural-tail--spider-legs)
10. [Spawn a particle emitter](#10-spawn-a-particle-emitter)
11. [Apply a force field](#11-apply-a-force-field)
12. [Rigid-body physics](#12-rigid-body-physics)
13. [Trigger volumes & area-of-effect queries](#13-trigger-volumes--area-of-effect-queries)
14. [Mouse picking via raycast](#14-mouse-picking-via-raycast)
15. [Build a navmesh & follow a path](#15-build-a-navmesh--follow-a-path)
16. [Render a minimap to texture](#16-render-a-minimap-to-texture)
17. [Add post-process effects](#17-add-post-process-effects)
18. [Build a HUD with the UI system](#18-build-a-hud-with-the-ui-system)
19. [Custom orbit / follow camera](#19-custom-orbit--follow-camera)
20. [Hot-reloading a texture](#20-hot-reloading-a-texture)
21. [Background loading pattern](#21-background-loading-pattern)

---

## 1. Hello cube

**Goal.** Smallest possible app. Single red cube.

**Modules.** `mjolnir`, `mjolnir/world`.

```odin
package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.spawn_primitive_mesh(&engine.world, .CUBE, .RED)
    world.main_camera_look_at(&engine.world, {3, 2, 3}, {0, 0, 0})
  }
  mjolnir.run(engine, 800, 600, "Cube")
}
```

**Notes.**
- `setup_proc` runs once, after GPU init. `update_proc` runs per tick.
- `mjolnir.run` blocks until window close. Returns to caller.
- Builtin meshes (`.CUBE`, `.SPHERE`, `.QUAD_XZ`, `.CONE`, `.CAPSULE`,
  `.CYLINDER`, `.TORUS`) and colors (`.RED`, `.GREEN`, ...) are pre-baked at
  `world.init`. You can use them anywhere by handle.

---

## 2. Move and rotate a node

**Goal.** Animate a single node from `update_proc`.

```odin
node: world.NodeHandle

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  node, _ = world.spawn_primitive_mesh(&engine.world, .CUBE, .BLUE)
  world.main_camera_look_at(&engine.world, {3, 2, 3}, {0, 0, 0})
}

engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Spin around Y axis at π/2 rad/sec
  world.rotate_by(&engine.world, node, delta_time * math.PI * 0.5)
  // Drift up
  world.translate_by(&engine.world, node, y = delta_time * 0.5)
}
```

**Notes.**

- `*_by` variants are *relative*. `translate`, `rotate`, `scale` (no `_by`)
  set absolute values.
- Rotations accept a quaternion or `(angle, axis)`. Default axis is +Y.
- Mutating a node automatically stages the new transform — see
  [architecture §5](architecture.html#5-the-staging-pipeline-cpu-mutation--gpu-upload).

---

## 3. Spawn a primitive grid

**Goal.** 100 × 100 cubes with one builtin mesh+material reused.

```odin
engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  for x in -50 ..< 50 {
    for z in -50 ..< 50 {
      world.spawn_primitive_mesh(
        &engine.world,
        primitive    = .CUBE,
        color        = .GREEN,
        position     = {f32(x), 0, f32(z)},
        scale_factor = 0.4,
      )
    }
  }
  world.main_camera_look_at(&engine.world, {80, 40, 80}, {0, 0, 0})
}
```

**Notes.**

- One mesh + one material handle, 10 000 nodes. The bindless model means
  each draw is a u32 lookup; the GPU eats this.
- `spawn_primitive_mesh` is the convenience wrapper. For full control use
  `world.spawn(world, position, MeshAttachment{handle=..., material=...})`.

---

## 4. Add lights and shadows

**Goal.** One spot light casting shadow on a plane.

```odin
engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  // Floor
  world.spawn_primitive_mesh(
    &engine.world, .QUAD_XZ, .GRAY,
    position = {0, 0, 0}, scale_factor = 20,
  )
  // Caster
  world.spawn_primitive_mesh(&engine.world, .CUBE, .RED, position = {0, 1, 0})

  // Spot light
  light, _ := world.spawn(
    &engine.world,
    {3, 6, 3},
    world.create_spot_light_attachment(
      color       = {1, 0.9, 0.7, 1},
      radius      = 30,
      angle       = math.PI * 0.25,
      cast_shadow = true,
    ),
  )
  // Aim it at origin
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)

  world.main_camera_look_at(&engine.world, {6, 5, 6}, {0, 0, 0})
}
```

**Notes.**

- `cast_shadow = true` on the attachment allocates a 2D shadow map
  (`SHADOW_MAP_SIZE = 512`). Set `false` to save VRAM.
- For point lights cubemap shadow you must build with
  `-define:REQUIRE_GEOMETRY_SHADER=true`.
- Per-mesh shadow casting is set on the `MeshAttachment.cast_shadow` field;
  receivers are everyone in the geometry pass.

---

## 5. Load a glTF model

**Goal.** Load `Duck.glb`, animate it, find its skinned mesh.

```odin
roots: [dynamic]world.NodeHandle

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  roots = mjolnir.load_gltf(engine, "assets/Duck.glb")
  for h in roots {
    n := world.node(&engine.world, h) or_continue
    log.infof("loaded root: %s", n.name)
  }
  world.main_camera_look_at(&engine.world, {3, 2, 3}, {0, 0, 0})
}

engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
  for h in roots {
    world.rotate_by(&engine.world, h, delta_time)
  }
}
```

**Notes.**

- `mjolnir.load_gltf` returns *root* nodes. Children are wired in the scene
  graph automatically.
- Embedded textures upload via `gpu.create_texture_2d_from_data`. PBR
  parameters (metallic/roughness/emissive maps) are picked up.
- `load_gltf` blocks. For background loading see recipe 21.

---

## 6. Play a skeletal animation

**Goal.** Find first skinned child, play `walk` looping.

```odin
engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  roots := mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
  for h in roots {
    if mesh_h, _, _, ok := world.find_first_mesh_child(&engine.world, h); ok {
      world.play_animation(&engine.world, mesh_h, "anim_0", mode = .LOOP)
    }
  }
  world.main_camera_look_at(&engine.world, {2, 2, 2}, {0, 0.8, 0})
}
```

**Notes.**

- Animation names match the glTF `animations[i].name`. If empty, mjolnir
  assigns `anim_0`, `anim_1`, ...
- `play_animation` adds to layer 0 with weight 1.0. For multi-layer blends
  see recipe 7.

---

## 7. Blend two animations on layers

**Goal.** Crossfade walk → run by holding W.

```odin
char: world.NodeHandle

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  roots := mjolnir.load_gltf(engine, "assets/Fox.glb")
  if mesh_h, _, _, ok := world.find_first_mesh_child(&engine.world, roots[0]); ok {
    char = mesh_h
    world.add_animation_layer(&engine.world, char, "Walk", weight = 1.0, layer_index = 0)
    world.add_animation_layer(&engine.world, char, "Run",  weight = 0.0, layer_index = 1)
  }
}

run_blend: f32 = 0.0

engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // glfw key 'W' = 87
  target: f32 = engine.input.keys[87] ? 1.0 : 0.0
  run_blend = math.lerp(run_blend, target, math.min(1.0, delta_time * 4))
  world.set_animation_layer_weight(&engine.world, char, 0, 1.0 - run_blend)
  world.set_animation_layer_weight(&engine.world, char, 1, run_blend)
}
```

**Notes.**

- Layer indices are user-assigned; pick stable numbers for "walk slot",
  "run slot", "upper-body" etc.
- `BlendMode` defaults to `.REPLACE` (weighted blend). Use `.ADD` for
  additive (e.g. recoil on top of aim). See `api_world.md` §animation.
- For a one-shot smooth transition use `transition_to_animation`.

---

## 8. Add IK head tracking

**Goal.** Make a character look at a moving target.

```odin
char: world.NodeHandle
target_world: [3]f32 = {2, 1.6, 0}

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  roots := mjolnir.load_gltf(engine, "assets/Fox.glb")
  mesh_h, _, _, ok := world.find_first_mesh_child(&engine.world, roots[0])
  if !ok do return
  char = mesh_h
  world.play_animation(&engine.world, char, "Walk")
  world.add_ik_layer(
    &engine.world,
    char,
    bone_names      = {"spine_03", "neck_01", "head"},
    target_world_pos = target_world,
    pole_world_pos  = {0, 3, 0},
    weight          = 1.0,
    max_iterations  = 8,
    layer_index     = 1,           // on top of walk on layer 0
  )
}

engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  target_world = {math.cos(t)*2, 1.6, math.sin(t)*2}
  world.set_ik_layer_target(&engine.world, char, 1, target_world, {0, 3, 0})
}
```

**Notes.**

- Bone name list goes from root of the chain to the tip. Min 2 bones.
- Pole vector controls bending plane (knee/elbow direction). For a head
  chain, place pole well above the chain.
- `weight = 0` disables the IK without removing the layer.

---

## 9. Procedural tail / spider legs

**Goal.** Add follow-through tail wave to a snake; add procedural legs to a
spider.

```odin
// Tail
world.add_tail_modifier_layer(
  &engine.world,
  snake,
  root_bone_name    = "tail_01",
  tail_length       = 6,
  propagation_speed = 0.5,
  damping           = 0.9,
  weight            = 1.0,
  layer_index       = 1,
)

// Spider legs
configs := [?]anim.SpiderLegConfig{
  {initial_offset = { 1.2, 0, 0.5}, lift_height = 0.3, lift_frequency = 2.0, lift_duration = 0.4, time_offset = 0.0},
  {initial_offset = {-1.2, 0, 0.5}, lift_height = 0.3, lift_frequency = 2.0, lift_duration = 0.4, time_offset = 0.5},
  // ...repeat for all legs
}
world.add_spider_leg_modifier_layer(
  &engine.world,
  spider,
  leg_root_names    = {"leg_l1_01", "leg_r1_01" /*, ...*/},
  leg_chain_lengths = {3, 3 /*, ...*/},
  leg_configs       = configs[:],
  weight            = 1.0,
  layer_index       = 0,
)
```

**Notes.**

- Tail driver: combine with `add_single_bone_rotation_modifier_layer` on a
  driver bone to feed motion into the tail (see `examples/tail_modifier`).
- Spider legs use FABRIK internally + a parabolic foot lift. Time offsets
  per leg create a gait pattern.
- Set `propagation_speed` low for stiff tails, high for whippy.

---

## 10. Spawn a particle emitter

**Goal.** Steady fire-cone emitter from a node.

```odin
engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  fire_tex, _ := mjolnir.create_texture_from_path(engine, "assets/fire.png")
  emitter_node, _ := world.spawn(&engine.world, {0, 0, 0})
  world.create_emitter(
    &engine.world,
    node_handle       = emitter_node,
    texture_handle    = fire_tex,
    emission_rate     = 200,           // particles/sec
    initial_velocity  = {0, 4, 0},
    velocity_spread   = 1.5,
    color_start       = {1, 0.9, 0.2, 1},
    color_end         = {1, 0.2, 0,   0},
    aabb_min          = {-0.5, 0, -0.5},
    aabb_max          = { 0.5, 0,  0.5},
    particle_lifetime = 1.5,
    position_spread   = 0.2,
    size_start        = 0.4,
    size_end          = 0.05,
    weight            = -0.3,          // negative = upward drift
    weight_spread     = 0.1,
  )
}
```

**Notes.**

- The emitter follows its node — translate the node, the source moves.
- `weight` is gravity-like; negative floats particles up.
- Particles are simulated and compacted on the GPU. Cap is
  `MAX_PARTICLES = 65536`.

---

## 11. Apply a force field

**Goal.** Vortex that pulls + curves nearby particles.

```odin
ff_node, _ := world.spawn(&engine.world, {2, 1, 0})
world.create_forcefield(
  &engine.world,
  node_handle      = ff_node,
  area_of_effect   = 5.0,
  strength         = 8.0,    // radial pull
  tangent_strength = 6.0,    // swirl
)
```

**Notes.**

- Up to `MAX_FORCE_FIELDS = 32`.
- Combine with multiple emitters for explosions, smoke columns, etc.

---

## 12. Rigid-body physics

**Goal.** Falling cubes onto a static ground. Single global physics world.

```odin
physics_world: physics.World

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  physics.init(&physics_world, gravity = {0, -9.81, 0})

  ground_node, _ := world.spawn(&engine.world, {0, -0.5, 0})
  ground := world.node(&engine.world, ground_node)
  physics.create_static_body_box(
    &physics_world, half_extents = {20, 0.5, 20},
    position = ground.transform.position,
    rotation = ground.transform.rotation,
  )
  // visual child for the ground
  world.spawn_child(&engine.world, ground_node,
    attachment = world.MeshAttachment{
      handle   = world.get_builtin_mesh(&engine.world, .CUBE),
      material = world.get_builtin_material(&engine.world, .GRAY),
    })
  world.scale_xyz(&engine.world, ground_node, 20, 0.5, 20)

  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  cube_mat  := world.get_builtin_material(&engine.world, .RED)
  for i in 0 ..< 25 {
    pos: [3]f32 = {f32(i % 5) - 2, 5 + f32(i / 5) * 1.5, 0}
    n, _ := world.spawn(&engine.world, pos)
    body := physics.create_dynamic_body_box(
      &physics_world, {1, 1, 1},
      position = pos, mass = 1.0,
    )
    if b, ok := physics.get_dynamic_body(&physics_world, body); ok {
      physics.set_box_inertia(b, {1, 1, 1})
    }
    np := world.node(&engine.world, n)
    np.attachment = world.RigidBodyAttachment{body_handle = body}
    world.spawn_child(&engine.world, n,
      attachment = world.MeshAttachment{handle=cube_mesh, material=cube_mat, cast_shadow=true})
  }
}

engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
  physics.step(&physics_world, delta_time)
  world.sync_all_physics_to_world(&engine.world, &physics_world)
}
```

**Notes.**

- Always pair `physics.step` with `world.sync_all_physics_to_world` — the
  step mutates rigid-body transforms, the sync writes them back to the node
  scene graph (and thus to the GPU via staging).
- `set_*_inertia` must be called *after* `create_dynamic_body_*` if you
  want correct angular response. Without it the inertia tensor is the unit
  default and rotations look unrealistic.
- `KILL_Y = -50.0` (default) — bodies that fall below it are killed.

---

## 13. Trigger volumes & area-of-effect queries

**Goal.** Detect units inside a fan-shaped damage zone.

```odin
zone := physics.create_trigger_fan(
  &physics_world,
  radius = 6.0, height = 2.0, angle = math.PI * 0.5,
  position = {0, 1, 0},
)

// In update:
hits: [dynamic]physics.DynamicRigidBodyHandle
defer delete(hits)
physics.query_trigger(&physics_world, zone, &hits)
for h in hits {
  // apply damage / push / mark
}
```

**Bulk sphere query (no trigger):**

```odin
hits: [dynamic]physics.DynamicRigidBodyHandle
physics.query_sphere(&physics_world, center = pos, radius = 10, results = &hits)
```

**Notes.**

- Triggers don't generate contacts. They overlap-test only.
- `physics.step` automatically populates `physics_world.trigger_overlaps` for
  active triggers; query the world list if you want continuous overlap events.
- Both BVHs accelerate these queries; cost is ~log N for typical scenes.

---

## 14. Mouse picking via raycast

**Goal.** Click on the world; identify the body under cursor.

```odin
engine.mouse_press_proc = proc(engine: ^mjolnir.Engine, button, action, mods: int) {
  if action != 1 || button != 0 do return  // left click down only

  cam, _ := world.camera(&engine.world, engine.world.main_camera)
  origin, dir := world.camera_viewport_to_world_ray(
    cam,
    f32(engine.cursor_pos.x),
    f32(engine.cursor_pos.y),
  )
  hit := physics.raycast(&physics_world, geometry.Ray{origin, dir}, max_dist = 1000)
  if hit.hit {
    log.infof("hit body=%v t=%.2f point=%v", hit.body_handle, hit.t, hit.point)
  }
}
```

**Notes.**

- `cursor_pos` is in pixels. `viewport_to_world_ray` does NDC unproject.
- `BodyHandleResult` is a union of dynamic/static/trigger handles. Switch
  on it to act accordingly.
- For triggers only: `physics.raycast_trigger`.

---

## 15. Build a navmesh & follow a path

**Goal.** Tag environment, bake navmesh, query path from A to B.

```odin
engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  // tag floor / walls / props
  floor, _ := world.spawn_primitive_mesh(&engine.world, .QUAD_XZ, .GRAY, scale_factor = 30)
  world.tag_node(&engine.world, floor, {.ENVIRONMENT})
  // ...spawn obstacles, tag them too...

  ok := mjolnir.setup_navmesh(
    engine,
    config         = mjolnir.DEFAULT_NAVMESH_CONFIG,  // MEDIUM quality
    include_filter = {.ENVIRONMENT},
  )
  if !ok do log.error("navmesh build failed")

  path, found := nav.find_path(&engine.nav, start = {-10, 0, -10}, end = {10, 0, 10})
  if found {
    for p in path do log.infof("waypoint: %v", p)
  }
}
```

**Notes.**

- `setup_navmesh` calls `world.bake_geometry` with the provided filters,
  then runs the Recast pipeline. Heavy — do it once at setup or after major
  scene changes.
- Quality presets (LOW/MEDIUM/HIGH/ULTRA) trade voxel resolution for build
  time. Tune `agent_radius` / `agent_max_climb` to your character.
- Walking the path is on you (lerp the agent toward each waypoint).

---

## 16. Render a minimap to texture

**Goal.** Top-down orthographic view of the scene, drawn as a UI quad.

```odin
minimap_cam: world.CameraHandle

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  c: world.Camera
  world.camera_init_orthographic(
    &c, width = 256, height = 256,
    enabled_passes = {.GEOMETRY, .LIGHTING},
    camera_position = {0, 50, 0},
    camera_target   = {0, 0, 0},
    ortho_width = 30, ortho_height = 30,
    near_plane = 0.1, far_plane = 100,
  )
  // Insert into world.cameras pool
  // (real code: see world.create_camera in api_world.md)

  // Once per frame, sample its FINAL_IMAGE as a UI quad.
}

engine.pre_render_proc = proc(engine: ^mjolnir.Engine) {
  if tex, ok := mjolnir.get_camera_attachment(engine, minimap_cam, .FINAL_IMAGE); ok {
    // Draw a UI quad sampling `tex` in the corner.
    // ui.create_quad2d(&engine.ui, position={1500, 20}, size={256,256}, texture=tex)
  }
}
```

**Notes.**

- A camera's `enabled_passes` controls which passes run for it. Skip
  `POST_PROCESS`, `UI` for non-main cameras.
- The returned `Texture2DHandle` is bindless — you can sample it from any
  shader, not only UI.

---

## 17. Add post-process effects

**Goal.** Bloom + tonemap + slight grain.

```odin
import pp "../../mjolnir/render/post_process"

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  // Cube scene...

  pp.add_effect(&engine.render.post_process, pp.BloomEffect{
    threshold   = 1.0,
    intensity   = 0.6,
    blur_radius = 4.0,
    direction   = 0.0,
  })
  pp.add_effect(&engine.render.post_process, pp.ToneMapEffect{
    exposure = 1.0, gamma = 2.2,
  })
}
```

Available effects: `GrayscaleEffect`, `ToneMapEffect`, `BlurEffect`,
`BloomEffect`, `OutlineEffect`, `FogEffect`, `CrossHatchEffect`, `DoFEffect`.

**Notes.**

- Effects run in the order added. Order matters (bloom before tonemap, fog
  before bloom for atmospheric falloff, etc.).
- Toggle by clearing and re-adding: `pp.clear_effects(&engine.render.post_process)`.

---

## 18. Build a HUD with the UI system

**Goal.** Health bar + click-able button.

```odin
import "../../mjolnir/ui"

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  // Background panel
  bg, _ := ui.create_quad2d(
    &engine.ui, position = {20, 20}, size = {300, 60},
    color = {30, 30, 30, 220}, z_order = 0,
  )
  // Health fill
  hp, _ := ui.create_quad2d(
    &engine.ui, position = {30, 30}, size = {280, 20},
    color = {220, 60, 60, 255}, z_order = 1,
  )
  // Label
  ui.create_text2d(
    &engine.ui, position = {30, 55}, text = "HP", font_size = 16,
    color = {255, 255, 255, 255}, z_order = 2,
  )
  // Button
  btn, _ := ui.create_quad2d(
    &engine.ui, position = {20, 100}, size = {120, 36},
    color = {60, 90, 200, 255}, z_order = 0,
  )
  ui.set_event_handler(ui.get_widget(&engine.ui, btn), ui.EventHandlers{
    on_mouse_down = proc(e: ui.MouseEvent) { log.info("clicked!") },
  })
}
```

**Notes.**

- Coordinates are pixels, origin top-left.
- Widget z-order is per widget; higher draws on top.
- Hit-testing is done in `update_input` — widgets get `HOVER_IN`,
  `HOVER_OUT`, `CLICK_DOWN`, `CLICK_UP` events automatically.

---

## 19. Custom orbit / follow camera

**Goal.** Disable the built-in controllers and write your own.

```odin
engine.camera_controller_enabled = false

target: [3]f32

engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
  cam, ok := world.camera(&engine.world, engine.world.main_camera)
  if !ok do return
  // chase target with smoothing
  desired := target + [3]f32{0, 4, -6}
  cam.position = math.lerp(cam.position, desired, math.min(1.0, delta_time * 4))
  world.camera_look_at(cam, cam.position, target)
}
```

Or use a built-in:

```odin
engine.world.orbit_controller = world.camera_controller_orbit_init(
  engine.window, target = {0, 0, 0}, distance = 10, yaw = 0, pitch = 0.4,
)
engine.world.active_controller = &engine.world.orbit_controller
```

**Notes.**

- The engine sets `active_controller` to orbit by default.
- Controllers are stateful; sync with `camera_controller_sync` after warp.
