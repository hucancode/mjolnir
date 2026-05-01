# `mjolnir/world` — API Reference

Layer 2. Scene graph, builtin meshes / materials / cameras, animation
application layer, glTF / OBJ loaders, sprite + emitter + force-field
attachments. The CPU-side authoritative state.

All mutations stage to GPU on next `engine.sync_staging_to_gpu`. See
[architecture §5](architecture.html#5-the-staging-pipeline-cpu-mutation--gpu-upload).

## Handles

```odin
NodeHandle       :: distinct cont.Handle
MeshHandle       :: distinct cont.Handle
MaterialHandle   :: distinct cont.Handle
CameraHandle     :: distinct cont.Handle
EmitterHandle    :: distinct cont.Handle
ForceFieldHandle :: distinct cont.Handle
ClipHandle       :: distinct cont.Handle
SpriteHandle     :: distinct cont.Handle
LightHandle      :: distinct cont.Handle

MAX_CAMERAS :: 64
```

## World

```odin
World :: struct {
  root:                NodeHandle,
  nodes:               Pool(Node),
  traversal_stack:     [dynamic]TraverseEntry,
  staging:             StagingList,
  animatable_nodes:    [dynamic]NodeHandle,
  meshes:              Pool(Mesh),
  materials:           Pool(Material),
  cameras:             Pool(Camera),
  main_camera:         CameraHandle,
  emitters:            Pool(Emitter),
  forcefields:         Pool(ForceField),
  sprites:             Pool(Sprite),
  animation_clips:     Pool(anim.Clip),
  active_light_nodes:  [dynamic]NodeHandle,
  builtin_materials:   [len(Color)]MaterialHandle,
  builtin_meshes:      [len(Primitive)]MeshHandle,
  orbit_controller:    CameraController,
  free_controller:     CameraController,
  active_controller:   ^CameraController,
}
```

```odin
init     (world)
shutdown (world)
begin_frame(world, delta_time = 0.016, game_state: rawptr = nil)
traverse (world) -> bool
```

## Capacity constants (`constants.odin`)

```odin
FRAMES_IN_FLIGHT     :: #config(FRAMES_IN_FLIGHT, 2)
MAX_NODES_IN_SCENE   :: 65536
MAX_ACTIVE_CAMERAS   :: 128
MAX_EMITTERS         :: 64
MAX_FORCE_FIELDS     :: 32
MAX_LIGHTS           :: 256
MAX_MESHES           :: 65536
MAX_MATERIALS        :: 4096
MAX_SPRITES          :: 4096
```

## Node & attachments

```odin
Node :: struct {
  parent:          NodeHandle,
  children:        [dynamic]NodeHandle,
  transform:       geometry.Transform,
  name:            string,
  bone_socket:     string,           // optional bone-attach point
  attachment:      NodeAttachment,
  animation:       Maybe(AnimationInstance),
  culling_enabled: bool,
  visible:         bool,
  parent_visible:  bool,
  tags:            NodeTagSet,
}

NodeAttachment :: union {
  PointLightAttachment,
  DirectionalLightAttachment,
  SpotLightAttachment,
  MeshAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
  SpriteAttachment,
  RigidBodyAttachment,
}
```

```odin
PointLightAttachment       :: struct { color: [4]f32, radius: f32, cast_shadow: bool }
DirectionalLightAttachment :: struct { color: [4]f32, radius: f32, cast_shadow: bool }
SpotLightAttachment        :: struct { color: [4]f32, radius: f32, angle_inner, angle_outer: f32, cast_shadow: bool }
MeshAttachment             :: struct { handle: MeshHandle, material: MaterialHandle, skinning: Maybe(NodeSkinning), cast_shadow: bool }
EmitterAttachment          :: struct { handle: EmitterHandle }
ForceFieldAttachment       :: struct { handle: ForceFieldHandle }
SpriteAttachment           :: struct { sprite_handle: SpriteHandle, mesh_handle: MeshHandle, material: MaterialHandle }
RigidBodyAttachment        :: struct { body_handle: physics.DynamicRigidBodyHandle }

NodeSkinning :: struct {
  layers:            [dynamic]anim.Layer,
  active_transition: Maybe(anim.Transition),
  matrices:          []matrix[4, 4]f32,
}
```

```odin
NodeTag :: enum u32 {
  PAWN, ACTOR, MESH, SPRITE, LIGHT, EMITTER, FORCEFIELD,
  VISIBLE, NAVMESH_AGENT, NAVMESH_OBSTACLE,
  INTERACTIVE, ENEMY, FRIENDLY, PROJECTILE,
  STATIC, DYNAMIC, ENVIRONMENT,
}
NodeTagSet :: bit_set[NodeTag; u32]
```

### Lookups

```odin
node      (w: ^World, h: NodeHandle)       -> (^Node, bool)
mesh      (w: ^World, h: MeshHandle)       -> (^Mesh, bool)
material  (w: ^World, h: MaterialHandle)   -> (^Material, bool)
camera    (w: ^World, h: CameraHandle)     -> (^Camera, bool)
clip      (w: ^World, h: ClipHandle)       -> (^anim.Clip, bool)
emitter   (w: ^World, h: EmitterHandle)    -> (^Emitter, bool)
forcefield(w: ^World, h: ForceFieldHandle) -> (^ForceField, bool)
sprite    (w: ^World, h: SpriteHandle)     -> (^Sprite, bool)
```

### Tags

```odin
tag_node   (world, handle, tags: NodeTagSet) -> bool
untag_node (world, handle, tags: NodeTagSet) -> bool
update_node_tags(node)        // reapply tags from attachment + visibility
```

### Spawn / despawn

```odin
spawn      (world, position = {0,0,0}, attachment: NodeAttachment = nil) -> (NodeHandle, bool)
spawn_child(world, parent, position = {0,0,0}, attachment: NodeAttachment = nil) -> (NodeHandle, bool)
despawn    (world, handle) -> bool        // recursive
init_node  (self: ^Node, name = "")
destroy_node(self: ^Node, world: ^World = nil, node_handle: NodeHandle = {})
attach     (nodes: Pool(Node), parent_handle, child_handle: NodeHandle)
detach     (nodes: Pool(Node), child_handle: NodeHandle)
register_animatable_node  (world, handle)
unregister_animatable_node(world, handle)
```

### Transform mutators (`node.odin`)

`*_by` adds; non-`_by` sets absolute. All stage automatically.

```odin
translate_by(world, handle, x=0, y=0, z=0)
translate   (world, handle, x=0, y=0, z=0)
rotate_by   (world, handle, q: quaternion128)
rotate_by   (world, handle, angle: f32, axis = Y)
rotate      (world, handle, q: quaternion128)
rotate      (world, handle, angle: f32, axis = Y)
scale_xyz_by(world, handle, x=1, y=1, z=1)
scale_by    (world, handle, s: f32)
scale_xyz   (world, handle, x=1, y=1, z=1)
scale       (world, handle, s: f32)
```

### Light helpers

```odin
create_point_light_attachment      (color={1,1,1,1}, radius=10, cast_shadow=true) -> PointLightAttachment
create_directional_light_attachment(color={1,1,1,1}, radius=10, cast_shadow=false) -> DirectionalLightAttachment
create_spot_light_attachment       (color={1,1,1,1}, radius=10, angle=π·0.2, cast_shadow=true) -> SpotLightAttachment
```

### Physics sync

```odin
sync_all_physics_to_world(world, physics_world: ^physics.World)
```

Call after `physics.step` to copy rigid-body transforms into nodes that have a
`RigidBodyAttachment`.

## Mesh

```odin
Bone :: struct {
  children:            []u32,
  inverse_bind_matrix: matrix[4, 4]f32,
  name:                string,
}

Skinning :: struct {
  root_bone_index: u32,
  bones:           []Bone,
  bone_lengths:    []f32,
  bind_matrices:   []matrix[4, 4]f32,
  bone_depths:     []u32,
}

Mesh :: struct {
  aabb_min:                [3]f32,
  index_count:             u32,
  aabb_max:                [3]f32,
  skinning:                Maybe(Skinning),
  cpu_geometry:            Maybe(geometry.Geometry),
  auto_purge_cpu_geometry: bool,
}

Color     :: enum { WHITE, BLACK, GRAY, RED, GREEN, BLUE, YELLOW, CYAN, MAGENTA }
Primitive :: enum { CUBE, SPHERE, QUAD_XZ, QUAD_XY, CONE, CAPSULE, CYLINDER, TORUS }

BakedNodeInfo :: struct { tags: NodeTagSet, vertex_count, index_count: int }
```

```odin
bake_geometry(world, include_filter = {.ENVIRONMENT}, exclude_filter = {}, with_node_info = false)
              -> (geometry.Geometry, []BakedNodeInfo, bool)
bake         (world, include_filter = {.ENVIRONMENT}, exclude_filter = {}) -> (MeshHandle, bool)

find_first_mesh_child   (world, parent) -> (NodeHandle, ^Node, ^MeshAttachment, bool)
find_bone_by_name       (mesh, name)    -> (u32, bool)
build_bone_parent_map   (skin, allocator = context.allocator) -> map[u32]u32
find_bone_chain_to_root (skin, tip_name, root_name, allocator = context.allocator) -> ([]string, bool)
find_bones_by_names     (mesh, names, allocator = context.allocator) -> ([]u32, bool)
compute_bone_lengths    (skin)
calculate_bone_depths   (skin, allocator = context.allocator) -> []u32

mesh_init           (mesh, geometry: geometry.Geometry)
mesh_destroy        (mesh)
mesh_release_memory (mesh)         // drop CPU geometry
bone_destroy        (bone)

create_mesh (world, geometry, auto_purge = false) -> (MeshHandle, ^Mesh, bool)
destroy_mesh(world, handle)

sample_layers(mesh, world, layers: []anim.Layer, ik_targets: []anim.IKTarget,
              out_bone_matrices: []matrix[4,4]f32, delta_time: f32,
              node_world_matrix = MAT4_IDENTITY)
```

## Material

```odin
ShaderFeature :: enum {
  ALBEDO_TEXTURE, METALLIC_ROUGHNESS_TEXTURE, NORMAL_TEXTURE,
  EMISSIVE_TEXTURE, OCCLUSION_TEXTURE,
}
ShaderFeatureSet :: bit_set[ShaderFeature]

MaterialType :: enum {
  PBR, UNLIT, WIREFRAME, TRANSPARENT, RANDOM_COLOR, LINE_STRIP,
}

Material :: struct {
  features:           ShaderFeatureSet,
  base_color_factor:  [4]f32,
  metallic_value:     f32,
  roughness_value:    f32,
  emissive_value:     f32,
  type:               MaterialType,
  albedo:             gpu.Texture2DHandle,
  metallic_roughness: gpu.Texture2DHandle,
  normal:             gpu.Texture2DHandle,
  emissive:           gpu.Texture2DHandle,
  occlusion:          gpu.Texture2DHandle,
}
```

```odin
material_init(self, features, type, albedo, metallic_roughness, normal,
              emissive, occlusion, metallic_value, roughness_value,
              emissive_value, base_color_factor)

create_material(world,
                features = {}, type = .PBR,
                albedo_handle = {}, metallic_roughness_handle = {}, normal_handle = {},
                emissive_handle = {}, occlusion_handle = {},
                metallic_value = 0, roughness_value = 1, emissive_value = 0,
                base_color_factor = {1,1,1,1}) -> (MaterialHandle, bool)
```

## Camera

```odin
PassType :: enum {
  SHADOW, GEOMETRY, LIGHTING, TRANSPARENCY, PARTICLES, POST_PROCESS,
  SPRITE, WIREFRAME, LINE_STRIP, RANDOM_COLOR,
  DEBUG_UI, DEBUG_BONE, UI,
}
PassTypeSet :: bit_set[PassType]

PerspectiveProjection  :: struct { fov, aspect_ratio, near, far: f32 }
OrthographicProjection :: struct { width, height, near, far: f32 }
CameraProjection       :: union  { PerspectiveProjection, OrthographicProjection }

Camera :: struct {
  position:                  [3]f32,
  rotation:                  quaternion128,
  projection:                CameraProjection,
  extent:                    [2]u32,
  enabled_passes:            PassTypeSet,
  enable_culling:            bool,
  draw_list_source_handle:   CameraHandle,
}
```

```odin
create_camera(world, width, height,
              enabled_passes = {.GEOMETRY,.LIGHTING,.SHADOW,.TRANSPARENCY,...},
              position = {0,0,3}, target = {0,0,0},
              fov = π/2, near_plane = 0.1, far_plane = 100) -> (CameraHandle, bool)

camera_init           (camera, width, height, enabled_passes, position, target, fov, near, far) -> bool
camera_init_orthographic(camera, width, height, enabled_passes = {.SHADOW},
                         camera_position={0,0,0}, camera_target={0,0,-1},
                         ortho_width=100, ortho_height=100, near=1, far=1000) -> bool
camera_resize         (camera, width, height) -> bool
camera_update_aspect_ratio(camera, new_aspect_ratio: f32)

camera_view_matrix       (camera) -> matrix[4,4]f32
camera_projection_matrix (camera) -> matrix[4,4]f32
camera_forward / camera_right / camera_up (camera) -> [3]f32
camera_get_near_far      (camera) -> (f32, f32)

camera_look_at        (camera, from, to)
main_camera_look_at   (world, from, to)
camera_viewport_to_world_ray(camera, mouse_x, mouse_y) -> (origin, direction: [3]f32)
```

## Camera controller

```odin
CameraControllerType :: enum { ORBIT, FREE, FOLLOW, CINEMATIC }

OrbitCameraData :: struct {
  target: [3]f32, distance: f32, yaw: f32, pitch: f32,
  min_distance, max_distance: f32,
  min_pitch, max_pitch: f32,
  zoom_speed, rotate_speed, pan_speed: f32,
}
FreeCameraData  :: struct { move_speed, rotation_speed, boost_multiplier, mouse_sensitivity: f32 }
FollowCameraData :: struct { target: ^[3]f32, offset: [3]f32, follow_speed: f32, look_at_target: bool }

CameraController :: struct {
  type:           CameraControllerType,
  window:         glfw.WindowHandle,
  data:           union { OrbitCameraData, FreeCameraData, FollowCameraData },
  last_mouse_pos: [2]f64,
  mouse_delta:    [2]f64,
  scroll_delta:   f32,
  is_orbiting:    bool,
}

g_scroll_deltas: map[glfw.WindowHandle]f32
```

```odin
setup_camera_controller_callbacks(window)
get_scroll_delta_for_window(window) -> f32

camera_controller_orbit_init (window, target={0,0,0}, distance=5, yaw=0, pitch=0) -> CameraController
camera_controller_free_init  (window, move_speed=5, rotation_speed=2)             -> CameraController
camera_controller_follow_init(window, target: ^[3]f32, offset, follow_speed=5)    -> CameraController

camera_controller_orbit_update (controller, camera, delta_time)
camera_controller_free_update  (controller, camera, delta_time)
camera_controller_follow_update(controller, camera, delta_time)

camera_controller_orbit_sync   (controller, camera)
camera_controller_free_sync    (controller, camera)
camera_controller_sync         (controller, camera)        // dispatch by type

camera_controller_orbit_set_target  (controller, target)
camera_controller_orbit_set_distance(controller, distance)
camera_controller_orbit_set_yaw_pitch(controller, yaw, pitch)
camera_controller_free_set_speed       (controller, speed)
camera_controller_free_set_sensitivity (controller, sensitivity)
```

## Animation (applied)

```odin
AnimationInstance :: struct {
  clip_handle: ClipHandle,
  mode:        anim.PlayMode,
  status:      anim.Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

BoneWorldTransform        :: struct { position: [3]f32, rotation: quaternion128, mat: matrix[4,4]f32 }
BoneVisualizationInstance :: struct { position: [3]f32, color: [4]f32, scale: f32 }
```

```odin
init_animation_channel(world, clip, channel_idx,
  position_count=0, rotation_count=0, scale_count=0,
  position_fn: proc(i:int)->[3]f32 = nil,
  rotation_fn: proc(i:int)->quaternion128 = nil,
  scale_fn:    proc(i:int)->[3]f32 = nil,
  position_interpolation = .LINEAR, rotation_interpolation = .LINEAR, scale_interpolation = .LINEAR)

animation_instance_update (instance, delta_time)
update_skeletal_animations(world, delta_time)
update_node_animations    (world, delta_time)
update_sprite_animations  (world, delta_time)

play_animation(world, node, name, mode = .LOOP, speed = 1) -> bool

add_animation_layer    (world, node, name, weight=1, mode=.LOOP, speed=1, layer_index=-1, blend_mode=.REPLACE) -> bool
remove_animation_layer (world, node, layer_index) -> bool
set_animation_layer_weight(world, node, layer_index, weight) -> bool
clear_animation_layers (world, node) -> bool

create_bone_mask          (mesh, bone_names: []string, allocator=context.allocator) -> ([]bool, bool)
create_bone_chain_mask    (mesh, root_bone_name: string, allocator=context.allocator) -> ([]bool, bool)
set_animation_layer_bone_mask(world, node, layer_index, mask: []bool) -> bool

transition_to_animation(world, node, animation_name, duration,
                        from_layer=0, to_layer=1,
                        curve = .Linear, blend_mode = .REPLACE,
                        mode = .LOOP, speed = 1) -> bool

world_to_skeleton_local(node_world_inv: matrix[4,4]f32, world_pos: [3]f32) -> [3]f32
```

### IK

```odin
add_ik_layer       (world, node, bone_names: []string, target_world_pos: [3]f32, pole_world_pos: [3]f32,
                    weight=1, max_iterations=10, tolerance=0.001, layer_index=-1) -> bool
set_ik_layer_target(world, node, layer_index, target_world_pos, pole_world_pos) -> bool
set_ik_layer_enabled(world, node, layer_index, enabled: bool) -> bool

resolve_bone_chain(mesh, root_bone_name, chain_length: u32, allocator=context.allocator) -> ([]u32, bool)
```

### Procedural modifiers

```odin
add_tail_modifier_layer(world, node, root_bone_name, tail_length: u32,
                        propagation_speed=0.5, damping=0.9, weight=1,
                        layer_index=-1, reverse_chain=false) -> bool
set_tail_modifier_params(world, node, layer_index,
                         propagation_speed: Maybe(f32) = nil, damping: Maybe(f32) = nil) -> bool

add_path_modifier_layer(world, node, root_bone_name, tail_length: u32, path: [][3]f32,
                        offset=0, length=0, speed=0, loop=false, weight=1, layer_index=-1) -> bool
set_path_modifier_params(world, node, layer_index,
                         path: Maybe([][3]f32) = nil,
                         offset: Maybe(f32) = nil, length: Maybe(f32) = nil,
                         speed: Maybe(f32) = nil, loop: Maybe(bool) = nil) -> bool

add_spider_leg_modifier_layer(world, node, leg_root_names: []string, leg_chain_lengths: []u32,
                              leg_configs: []anim.SpiderLegConfig,
                              weight=1, layer_index=-1) -> bool
get_spider_leg_target        (world, node, layer_index, leg_index) -> (^[3]f32, bool)

add_single_bone_rotation_modifier_layer(world, node, bone_name, weight=1, layer_index=-1)
                                       -> (^anim.SingleBoneRotationModifier, bool)
```

### Bone introspection

```odin
get_bone_matrices       (world, node) -> ([]matrix[4,4]f32, ^Skinning, ^Node, bool)
get_bone_world_transform(world, node, bone_index: u32) -> (BoneWorldTransform, bool)
collect_bone_visualization_data(world, bone_palette: [][4]f32, bone_scale: f32,
                                allocator=context.allocator) -> [dynamic]BoneVisualizationInstance
```

## Animation clip

```odin
create_animation_clip(world, channel_count: int, duration = 1, name = "") -> (ClipHandle, bool)
```

## Sprite

```odin
SpriteAnimationState :: enum { PLAYING, PAUSED, STOPPED }
SpriteAnimationMode  :: enum { ONCE, LOOP, PINGPONG }

Sprite          :: struct { texture: gpu.Texture2DHandle, frame_columns, frame_rows: u32, animation: Maybe(SpriteAnimation) }
SpriteAnimation :: struct {
  frame_count, current_frame: u32, fps, time: f32,
  state: SpriteAnimationState, mode: SpriteAnimationMode, forward: bool,
}

sprite_init   (self, texture, frame_columns=1, frame_rows=1)
create_sprite (world, texture, frame_columns=1, frame_rows=1, animation: Maybe(SpriteAnimation)=nil) -> (SpriteHandle, bool)
destroy_sprite(world, handle)

sprite_animation_init(frame_count, fps=12, mode=.LOOP, forward=true) -> SpriteAnimation
sprite_animation_update    (anim, delta_time)
sprite_animation_play      (anim)
sprite_animation_pause     (anim)
sprite_animation_stop      (anim)
sprite_animation_set_frame (anim, frame: u32)
sprite_animation_set_mode  (anim, mode)
sprite_animation_set_direction(anim, forward: bool)
```

## Emitter & ForceField

```odin
Emitter :: struct {
  initial_velocity: [3]f32, size_start: f32,
  color_start, color_end: [4]f32,
  aabb_min, aabb_max: [3]f32,
  emission_rate: f32, particle_lifetime: f32,
  position_spread, velocity_spread: f32,
  size_end, weight, weight_spread: f32,
  enabled: b32,
  texture_handle: gpu.Texture2DHandle,
  node_handle:    NodeHandle,
}

ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  node_handle:      NodeHandle,
}

create_emitter(world, node, texture, emission_rate, initial_velocity, velocity_spread,
               color_start, color_end, aabb_min, aabb_max, particle_lifetime,
               position_spread, size_start, size_end, weight, weight_spread)
              -> (EmitterHandle, bool)
destroy_emitter(world, handle) -> bool

create_forcefield(world, node, area_of_effect, strength, tangent_strength)
                 -> (ForceFieldHandle, bool)
destroy_forcefield(world, handle) -> bool
```

## Builtin meshes / materials

```odin
spawn_primitive_mesh(world, primitive = .CUBE, color = .WHITE,
                     position = {0,0,0}, rotation_angle = 0,
                     rotation_axis = {0,1,0}, scale_factor = 1,
                     cast_shadow = true) -> (NodeHandle, bool)

get_builtin_material(world, color)     -> MaterialHandle
get_builtin_mesh    (world, primitive) -> MeshHandle
init_builtin_materials(world)
init_builtin_meshes  (world)
```

## glTF / OBJ loaders

```odin
TextureFromDataAllocator :: #type proc(pixel_data: []u8) -> (gpu.Texture2DHandle, bool)
Texture2DRefProc         :: #type proc(handle: gpu.Texture2DHandle) -> bool

load_gltf(world, create_texture_from_data: TextureFromDataAllocator, path: string)
         -> ([dynamic]NodeHandle, cgltf.result)

load_obj(world, path: string, material: MaterialHandle, scale = 1, cast_shadow = true)
        -> ([dynamic]NodeHandle, bool)
```

`mjolnir.load_gltf(engine, path)` is the engine-level wrapper that supplies a
texture allocator from `engine.render.texture_manager`. Most code should use it
instead of calling `world.load_gltf` directly.

## Staging (private)

The following are layer-2-private and exposed only for `engine.sync_staging_to_gpu`.
User code should not call them; mutation procs above stage automatically.

```odin
StagingOp   :: enum u16 { Update, Remove }
StagingEntry :: struct { age: u16, op: StagingOp }

StagingList :: struct {
  node_data, mesh_updates, material_updates, bone_updates, sprite_updates,
  emitter_updates, forcefield_updates, light_updates, camera_updates: map[<H>]StagingEntry,
  mutex: sync.Mutex,
}

staging_init  (^StagingList)
staging_destroy(^StagingList)

stage_node_data       (^StagingList, NodeHandle)
stage_node_data_removal(^StagingList, NodeHandle)
stage_mesh_data        (^StagingList, MeshHandle)
stage_mesh_removal     (^StagingList, MeshHandle)
stage_material_data    (^StagingList, MaterialHandle)
stage_material_removal (^StagingList, MaterialHandle)
stage_bone_matrices    (^StagingList, NodeHandle)
stage_bone_matrices_removal(^StagingList, NodeHandle)
stage_sprite_data      / stage_sprite_removal
stage_emitter_data     / stage_emitter_removal
stage_forcefield_data  / stage_forcefield_removal
stage_light_data       / stage_light_removal
stage_camera_data      / stage_camera_removal
```
