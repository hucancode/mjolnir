# World Module (`mjolnir/world`)

The World module manages the scene graph, nodes, meshes, materials, cameras, lights, and animations. It provides a hierarchical structure for organizing 3D objects and their relationships.

## Scene Graph Basics

### Spawning Nodes

```odin
import "../../mjolnir/world"
import cont "../../mjolnir/containers"

// Spawn a node with a mesh
mesh := world.get_builtin_mesh(&engine.world, .CUBE)
mat := world.get_builtin_material(&engine.world, .RED)
node := world.spawn(
  &engine.world,
  {0, 0, 0}, // position
  world.MeshAttachment{handle = mesh, material = mat, cast_shadow = true},
) or_else {}

// Spawn a child node
child := world.spawn_child(
  &engine.world,
  node, // parent handle
  position = {0, 2, 0},
  attachment = world.MeshAttachment{handle = mesh, material = mat},
) or_else {}
```

### Node Hierarchy

```odin
// Get node pointer
node_ptr := cont.get(engine.world.nodes, node) or_return

// Access node properties
log.infof("Node name: %s", node_ptr.name)
log.infof("Position: %v", node_ptr.transform.position)

// Iterate children
for child_handle in node_ptr.children {
  child := cont.get(engine.world.nodes, child_handle) or_continue
  log.infof("Child: %s", child.name)
}
```

## Transformations

All transformation functions have `_by` variants (relative) and absolute variants:

```odin
// Translate (absolute position)
world.translate(&engine.world, node, x = 5, y = 0, z = 0)

// Translate by offset (relative)
world.translate_by(&engine.world, node, x = 1, y = 0, z = 0)

// Rotate (absolute rotation)
world.rotate(&engine.world, node, math.PI * 0.5, {0, 1, 0})

// Rotate by angle (relative)
world.rotate_by(&engine.world, node, delta_time * math.PI)

// Scale (uniform)
world.scale(&engine.world, node, 2.0)

// Scale (non-uniform)
world.scale_xyz(&engine.world, node, x = 2, y = 1, z = 2)
```

## Creating Custom Geometry

```odin
import "../../mjolnir/geometry"

// Create custom geometry
geom := geometry.Geometry{
  vertices = vertices,
  indices = indices,
  aabb = geometry.aabb_from_vertices(vertices),
}

// Upload to GPU and get handle
mesh_handle, gpu_handle, ok := world.create_mesh(&engine.world, geom, keep_cpu_copy = false)

// Create material
material_handle, ok := world.create_material(
  &engine.world,
  type = .PBR,
  metallic_value = 0.5,
  roughness_value = 0.8,
  emissive_value = 0.1,
)

// Spawn with custom mesh
node := world.spawn(
  &engine.world,
  {0, 0, 0},
  world.MeshAttachment{handle = mesh_handle, material = material_handle},
) or_else {}
```

## Materials

```odin
// Builtin materials
mat := world.get_builtin_material(&engine.world, .RED)
// Available colors: .RED, .GREEN, .BLUE, .YELLOW, .CYAN, .MAGENTA, .WHITE, .GRAY, .BLACK

// Create PBR material
pbr_mat, ok := world.create_material(
  &engine.world,
  type = .PBR,
  base_color_factor = {1.0, 0.5, 0.2, 1.0},
  metallic_value = 0.8,
  roughness_value = 0.2,
  emissive_value = 0.5,
)

// Random color material (useful for debugging)
debug_mat, ok := world.create_material(
  &engine.world,
  type = .RANDOM_COLOR,
  base_color_factor = {1.0, 1.0, 1.0, 1.0},
)

// Line strip material
line_mat, ok := world.create_material(
  &engine.world,
  type = .LINE_STRIP,
  base_color_factor = {1.0, 0.8, 0.0, 1.0},
)
```

## Lights

```odin
// Directional light (sun)
light := world.spawn(
  &engine.world,
  {0, 10, 0},
  world.create_directional_light_attachment(
    color = {1.0, 1.0, 1.0, 1.0},
    intensity = 10.0,
    cast_shadow = true,
  ),
) or_else {}

// Point light
point_light := world.spawn(
  &engine.world,
  {5, 3, 5},
  world.create_point_light_attachment(
    color = {1.0, 0.8, 0.6, 1.0},
    intensity = 100.0,
    cast_shadow = false,
  ),
) or_else {}

// Spot light
spot_light := world.spawn(
  &engine.world,
  {0, 10, 0},
  world.create_spot_light_attachment(
    color = {0.8, 0.9, 1.0, 1.0},
    intensity = 50.0,
    outer_cone_angle = math.PI * 0.25,
    cast_shadow = true,
  ),
) or_else {}
```

## Camera Control

```odin
// Position camera looking at target
world.main_camera_look_at(
  &engine.world,
  engine.world.main_camera,
  eye_position = {10, 5, 10},
  target_position = {0, 0, 0},
)

// Mouse picking - convert screen to world ray
camera := cont.get(engine.world.cameras, engine.world.main_camera)
ray_origin, ray_dir := world.camera_viewport_to_world_ray(
  camera,
  mouse_x,
  mouse_y,
)
```

## Animation

### Playing Animations

```odin
// Load GLTF with animations
nodes := mjolnir.load_gltf(engine, "assets/CesiumMan.glb")

// Play animation on node
for handle in nodes {
  node := cont.get(engine.world.nodes, handle) or_continue
  for child in node.children {
    if world.play_animation(&engine.world, child, "Walk") {
      log.info("Animation started")
    }
  }
}
```

### Animation Layers

```odin
// Add animation layer (returns true if animation found)
success := world.add_animation_layer(
  &engine.world,
  node,
  animation_name = "Walk",
  weight = 1.0,
  blend_mode = .REPLACE, // or .ADD
  mode = .LOOP,
  speed = 1.0,
)

// Adjust layer weight
world.set_animation_layer_weight(&engine.world, node, layer_index = 0, weight = 0.5)

// Blend between two animations
world.set_animation_layer_weight(&engine.world, node, 0, walk_weight)
world.set_animation_layer_weight(&engine.world, node, 1, run_weight)
```

### IK (Inverse Kinematics)

```odin
// Add IK layer for a bone chain
bone_chain := []string{"Spine1", "Spine2", "Neck", "Head"}
target_pos := [3]f32{0, 2, 5}
pole_pos := [3]f32{0, 3, 2}

success := world.add_ik_layer(
  &engine.world,
  node,
  bone_chain,
  target_pos,
  pole_pos,
  weight = 1.0,
  layer_index = -1, // -1 to append
)

// Update IK target each frame
world.set_ik_layer_target(
  &engine.world,
  node,
  layer_index = 2,
  new_target,
  new_pole,
)
```

### Procedural Animation Modifiers

```odin
// Tail modifier - creates follow-through motion
success := world.add_tail_modifier_layer(
  &engine.world,
  node,
  root_bone_name = "tail_root",
  tail_length = 10,
  propagation_speed = 0.85, // How strongly bones react (0-1)
  damping = 0.1,            // How slowly they return (0-1)
  weight = 1.0,
  reverse_chain = false,
)

// Single bone rotation - control one bone directly
modifier := world.add_single_bone_rotation_modifier_layer(
  &engine.world,
  node,
  bone_name = "root",
  weight = 1.0,
  layer_index = -1,
) or_else nil

// Update rotation each frame
if modifier != nil {
  modifier.rotation = linalg.quaternion_angle_axis_f32(angle, {0, 1, 0})
}
```

## Bone Access Helpers

For reading bone world transforms after skinning computation:

```odin
// Get computed bone matrices for a skinned node
matrices, skin, node := world.get_bone_matrices(&engine.world, node_handle) or_continue

// Get world-space transform for a specific bone
bone_transform := world.get_bone_world_transform(
  &engine.world,
  node_handle,
  bone_index = u32(5),
) or_continue

// Use bone position/rotation
marker.transform.position = bone_transform.position
marker.transform.rotation = bone_transform.rotation
```

## Node Management

```odin
// Despawn a node and all its children
world.despawn(&engine.world, node)

// Destroy a mesh
world.destroy_mesh(&engine.world, mesh_handle)

// Traverse scene graph to update world matrices
world.traverse(&engine.world)
```

## Node Tags

```odin
// Tag nodes for specific purposes
if node := cont.get(engine.world.nodes, handle); node != nil {
  node.tags += {.ENVIRONMENT}        // For navmesh baking
  node.tags += {.NAVMESH_OBSTACLE}   // Mark as obstacle
}
```
