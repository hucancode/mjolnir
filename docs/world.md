---
title: World
---
# World Module (`mjolnir/world`)

The World module manages the scene graph: nodes, meshes, materials,
cameras, lights, and animations. Hierarchical transforms cascade through
parent → child.

> Most procs shown below take `^World`. From user code, prefer the
> engine-rooted shortcuts (`mjolnir.spawn`, `mjolnir.translate`, ...) — see
> [`api_engine` §Shortcuts](api_engine.html#shortcuts).

## Scene Graph Basics

### Spawning Nodes

```odin
mesh := mjolnir.builtin_mesh(engine, .CUBE)
mat  := mjolnir.builtin_material(engine, .RED)

node := mjolnir.spawn(
  engine,
  {0, 0, 0},
  world.MeshAttachment{handle = mesh, material = mat, cast_shadow = true},
)

child := mjolnir.spawn_child(
  engine, node,
  position   = {0, 2, 0},
  attachment = world.MeshAttachment{handle = mesh, material = mat},
)
```

### Node Hierarchy

```odin
node_ptr := mjolnir.node(engine, node) or_return
log.infof("Node name: %s", node_ptr.name)
log.infof("Position:  %v", node_ptr.transform.position)

for child_handle in node_ptr.children {
  child := mjolnir.node(engine, child_handle) or_continue
  log.infof("Child: %s", child.name)
}
```

## Transformations

All transform procs have `_by` variants (relative) and absolute variants:

```odin
mjolnir.translate    (engine, node, x = 5, y = 0, z = 0)   // absolute
mjolnir.translate    (engine, node, [3]f32{5, 0, 0})       // absolute, vec form
mjolnir.translate_by (engine, node, x = 1, y = 0, z = 0)   // relative

mjolnir.rotate       (engine, node, math.PI * 0.5, {0, 1, 0})       // absolute (angle, axis)
mjolnir.rotate       (engine, node, my_quat)                        // absolute (quaternion)
mjolnir.rotate_by    (engine, node, dt * math.PI)                   // relative

mjolnir.scale        (engine, node, 2.0)            // uniform
mjolnir.scale        (engine, node, [3]f32{2,1,2})  // vec
mjolnir.scale_xyz    (engine, node, x = 2, y = 1, z = 2)
```

## Creating Custom Geometry

```odin
import "../../mjolnir/geometry"

geom := geometry.Geometry{
  vertices = vertices,
  indices  = indices,
  aabb     = geometry.aabb_from_vertices(vertices),
}

mesh_handle := mjolnir.create_mesh(engine, geom)
material_handle := mjolnir.material_pbr(engine,
  metallic = 0.5, roughness = 0.8, emissive = 0.1)

mjolnir.spawn_mesh(engine, mesh_handle, material_handle, position = {0, 0, 0})
```

## Materials

```odin
// Builtin colors: .RED, .GREEN, .BLUE, .YELLOW, .CYAN, .MAGENTA, .WHITE, .GRAY, .BLACK
mat := mjolnir.builtin_material(engine, .RED)

pbr_mat := mjolnir.material_pbr(engine,
  base_color = {1.0, 0.5, 0.2, 1.0},
  metallic   = 0.8,
  roughness  = 0.2,
  emissive   = 0.5,
)

// Unlit / wireframe / transparent helpers
unlit_mat       := mjolnir.material_unlit(engine, base_color = {1, 1, 0, 1})
wire_mat        := mjolnir.material_wireframe(engine, base_color = {0, 1, 0, 1})
transparent_mat := mjolnir.material_transparent(engine, base_color = {0.2, 0.9, 0.4, 0.4})

// Full-control creator
custom := mjolnir.create_material(
  engine,
  type              = .RANDOM_COLOR,    // or .PBR, .LINE_STRIP, etc.
  base_color_factor = {1, 1, 1, 1},
)
```

## Lights

```odin
dir := mjolnir.spawn_light_directional(engine,
  position = {0, 10, 0}, color = {1, 1, 1, 10.0},
  radius   = 12, cast_shadow = true,
)

point := mjolnir.spawn_light_point(engine,
  position = {5, 3, 5}, color = {1, 0.8, 0.6, 100.0},
  radius   = 8, cast_shadow = false,
)

spot := mjolnir.spawn_light_spot(engine,
  position = {0, 10, 0}, color = {0.8, 0.9, 1, 50.0},
  radius   = 20, angle = math.PI * 0.25, cast_shadow = true,
)
```

The colour `w` channel doubles as intensity. Live-tune with
`set_light_color`, `set_light_intensity`, `set_light_radius`, or edit the
attachment struct directly and call `mjolnir.mark_light_dirty`.

## Camera Control

```odin
mjolnir.main_camera_look_at(engine, {10, 5, 10}, {0, 0, 0})

cam, _ := mjolnir.main_camera(engine)
ray_origin, ray_dir := world.camera_viewport_to_world_ray(cam, mouse_x, mouse_y)
```

## Animation

### Playing animations

```odin
nodes := mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
for handle in nodes {
  if mesh_node, ok := mjolnir.skinned_mesh(engine, handle); ok {
    mjolnir.play_animation(engine, mesh_node, "Anim_0")
  }
}
```

### Animation layers

```odin
idx, _ := mjolnir.add_animation_layer(
  engine, node, "Walk",
  weight     = 1.0,
  blend_mode = .REPLACE,    // or .ADD
  mode       = .LOOP,
  speed      = 1.0,
)

mjolnir.set_animation_layer_weight(engine, node, idx, 0.5)
```

### IK (Inverse Kinematics)

```odin
idx, _ := mjolnir.add_ik_layer(
  engine, node,
  bone_names     = []string{"Spine1", "Spine2", "Neck", "Head"},
  target_pos     = {0, 2, 5},
  pole_pos       = {0, 3, 2},
  weight         = 1.0,
  max_iterations = 10,
)

mjolnir.set_ik_layer_target(engine, node, idx, new_target, new_pole)
```

For a chain by root/tip name, use `mjolnir.add_ik_layer_chain`.

### Procedural modifiers

```odin
mjolnir.add_tail_modifier_layer(
  engine, node,
  root_bone_name    = "tail_root",
  tail_length       = 10,
  propagation_speed = 0.85,
  damping           = 0.1,
  weight            = 1.0,
)

mjolnir.add_path_modifier_layer(
  engine, node,
  root_bone_name = "tentacle_root",
  tail_length    = 8,
  path           = my_waypoints,
  speed          = 1.0,
  loop           = true,
)

mjolnir.add_spider_leg_modifier_layer(engine, node, legs_spec, weight = 1.0)
```

## Bone Access Helpers

```odin
m, _ := mjolnir.node_mesh(engine, node_handle)
offset, _ := world.bone_rest_offset(m, "leg_root", "leg_tip")
pos,    _ := world.bone_rest_position(m, "leg_tip")
```

## Node Management

```odin
mjolnir.despawn(engine, node)              // remove node + descendants
world.destroy_mesh(&engine.world, mesh_h)  // free a mesh
world.traverse(&engine.world)              // recompute world matrices
```

## Node Tags

```odin
mjolnir.tag(engine, ground_handle, {.ENVIRONMENT})
mjolnir.tag(engine, obstacle_handle, {.NAVMESH_OBSTACLE})
mjolnir.untag(engine, h, {.ENVIRONMENT})
```
