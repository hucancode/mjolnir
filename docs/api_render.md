# `mjolnir/render` — API Reference

Layer 2. The render manager + every render sub-system. The engine main loop
calls into one entry point — `record_frame` — which orchestrates the whole
pipeline. Everything else here is either a sub-renderer used by `record_frame`
or upload helpers used by `engine.sync_staging_to_gpu`.

See [architecture §2](architecture.html#2-frame-timeline) and
[architecture §8](architecture.html#8-deferred-shading--light-volumes) for the
overview.

## Directory layout

```
render/
├── render.odin               main orchestrator (~2500 lines)
├── ambient/                  ambient + IBL pass
├── debug_bone/               bone visualization
├── debug_ui/                 microui debug overlay
├── depth_pyramid/            hierarchical depth (occlusion accel)
├── direct_light/             point/spot/directional shading
├── geometry/                 G-buffer pass
├── line_strip/               polyline rendering
├── occlusion_culling/        compute-based culling
├── particles_compute/        emit + simulate + compact
├── particles_render/         point-sprite particles
├── post_process/             effect stack
├── random_color/             debug color
├── shadow_culling/           frustum cull per shadow caster
├── shadow_render/            2D shadow depth
├── shadow_sphere_culling/    sphere cull for point-light shadows
├── shadow_sphere_render/     cubemap shadow depth (geo shader)
├── shared/                   spec-constants shared by all pipelines
├── sprite/                   billboard sprites
├── transparent/              additive transparency
├── ui/                       UI widget rendering
└── wireframe/                wireframe pass
```

## Manager — orchestration

```odin
Manager :: struct {
  internal:        Internal,                  // private; GPU primitives + sub-renderers
  cameras:         map[u32]CameraTarget,
  mesh_manager:    gpu.MeshManager,
  texture_manager: gpu.TextureManager,
  post_process:    post_process.Renderer,
  debug_ui:        debug_ui.Renderer,
}

VisibilityStats :: struct {
  opaque_draw_count: u32,
  camera_index:      u32,
  frame_index:       u32,
}
```

```odin
init     (self, gctx, swapchain_extent, swapchain_format, dpi_scale: f32) -> vk.Result
setup    (self, gctx) -> vk.Result            // swapchain-dependent resources
teardown (self, gctx)                          // free swapchain-dependent resources
shutdown (self, gctx)                          // final cleanup
resize   (self, gctx, new_extent: vk.Extent2D) -> vk.Result
```

### Frame recording

```odin
record_frame(self, gctx, frame_index, swapchain_image, swapchain_view,
             swapchain_extent, main_camera_index: u32, main_camera_passes: PassTypeSet,
             cameras_config: []CameraFrameConfig, debug_ui_enabled: bool) -> vk.Result
```

`record_frame` runs (in this order):

1. `record_compute_commands` — culling + particle simulation
2. shadow cull + render (2D and cubemap)
3. `record_geometry_pass`
4. `record_lighting_pass` (ambient + direct)
5. `record_particles_pass`
6. `record_transparency_pass`
7. `record_debug_pass`
8. `record_post_process_pass`
9. `record_ui_pass`
10. swapchain → `PRESENT_SRC_KHR`

Public sub-passes you can call individually if you build a custom loop:

```odin
record_compute_commands(self, frame_index, gctx, cull_cameras: []u32) -> vk.Result
record_geometry_pass   (self, frame_index, camera_index, camera: ^CameraTarget, enabled_passes: PassTypeSet) -> vk.Result
record_lighting_pass   (self, frame_index, camera_index, camera, enabled_passes) -> vk.Result
record_particles_pass  (self, frame_index, camera_index, camera, enabled_passes) -> vk.Result
record_transparency_pass(self, frame_index, gctx, camera_index, camera, enabled_passes) -> vk.Result
record_debug_pass      (self, frame_index, camera_index, camera, enabled_passes) -> vk.Result
record_post_process_pass(self, frame_index, camera, swapchain_extent, swapchain_image, swapchain_view, enabled_passes) -> vk.Result
record_ui_pass         (self, frame_index, gctx, swapchain_view, swapchain_extent, enabled_passes)
render_shadow_depth    (self, frame_index) -> vk.Result
```

### Mesh management

```odin
sync_mesh_geometry_for_handle(gctx, render: ^Manager, handle: u32, geometry_data: geom.Geometry) -> vk.Result
mesh_destroy                 (render, handle: u32)
```

### Light management

```odin
upsert_light_entry  (self, light_node_index: u32, light: Light) -> vk.Result
remove_light_entry  (self, gctx, light_node_index: u32)
ensure_shadow_2d_resource  (render, gctx, light_node_index: u32) -> vk.Result
ensure_shadow_cube_resource(render, gctx, light_node_index: u32) -> vk.Result
release_shadow_2d  (render, gctx, light_node_index: u32)
release_shadow_cube(render, gctx, light_node_index: u32)
```

### Camera management

```odin
camera_init          (self, gctx, camera: ^CameraTarget, texture_manager,
                      extent, color_format, depth_format,
                      enabled_passes = {...}, enable_culling = true, max_draws: u32) -> vk.Result
camera_destroy       (gctx, camera, texture_manager)
camera_allocate_descriptors(self, gctx, camera) -> vk.Result
camera_resize        (self, gctx, camera_index: u32, new_extent: vk.Extent2D) -> vk.Result
```

### Upload (called by engine.sync_staging_to_gpu)

```odin
upload_node_data       (render, index: u32, node_data: ^Node)
upload_bone_matrices   (self,  handle: u32, matrices: []matrix[4,4]f32) -> vk.Result
upload_sprite_data     (render, index, sprite: ^Sprite)
upload_emitter_data    (render, index, emitter: ^Emitter)
upload_forcefield_data (render, index, forcefield: ^ForceField)
upload_mesh_data       (render, index, mesh: ^Mesh)
upload_material_data   (render, index, material: ^Material)
upload_camera_data     (self,  frame_index, camera_index, view, projection, frustum_planes: [6][4]f32) -> vk.Result
```

### Settings & stats

```odin
set_node_count             (self, node_count: u32)
set_particle_params        (self, emitter_count, forcefield_count: u32, delta_time: f32)
visibility_stats           (self, camera_index, frame_index: u32) -> VisibilityStats
set_visibility_stats_enabled(self, enabled: bool)
```

## Manager — data structures

```odin
Primitive :: enum { CUBE, SPHERE, QUAD_XZ, QUAD_XY, CONE, CAPSULE, CYLINDER, TORUS }

MeshFlag      :: enum u32 { SKINNED }
ShaderFeature :: enum     { ALBEDO_TEXTURE, METALLIC_ROUGHNESS_TEXTURE, NORMAL_TEXTURE, EMISSIVE_TEXTURE, OCCLUSION_TEXTURE }
NodeFlag      :: enum u32 {
  VISIBLE, CULLING_ENABLED, MATERIAL_TRANSPARENT, MATERIAL_WIREFRAME, MATERIAL_SPRITE,
  MATERIAL_RANDOM_COLOR, MATERIAL_LINE_STRIP, CASTS_SHADOW, NAVIGATION_OBSTACLE,
}
AttachmentType :: enum {
  POSITION, NORMAL, ALBEDO, METALLIC_ROUGHNESS, EMISSIVE, FINAL_IMAGE, DEPTH,
}
PassType :: enum {
  SHADOW, GEOMETRY, LIGHTING, TRANSPARENCY, PARTICLES, SPRITE, WIREFRAME, LINE_STRIP,
  RANDOM_COLOR, POST_PROCESS, DEBUG_UI, DEBUG_BONE, UI,
}
```

```odin
Node :: struct #packed {
  world_matrix: matrix[4, 4]f32,
  material_id, mesh_id, attachment_data_index: u32,
  flags: NodeFlagSet,
}

Mesh :: struct {
  aabb_min: [3]f32,  index_count:       u32,
  aabb_max: [3]f32,  first_index:       u32,
  vertex_offset: i32, skinning_offset:  u32,
  flags: MeshFlagSet, padding:          u32,
}

Material :: struct {
  albedo_index, metallic_roughness_index, normal_index, emissive_index: u32,
  metallic_value, roughness_value, emissive_value: f32,
  features: ShaderFeatureSet,
  base_color_factor: [4]f32,
}

Sprite :: struct { texture_index, frame_columns, frame_rows, frame_index: u32 }

CameraGPU :: struct {
  view, projection: matrix[4, 4]f32,
  viewport_extent:  [2]f32,
  near, far:        f32,
  position:         [4]f32,
  frustum_planes:   [6][4]f32,
}

PointLight       :: struct { color: [4]f32, position: [3]f32, radius: f32 }
SpotLight        :: struct { color: [4]f32, position, direction: [3]f32, radius, angle_inner, angle_outer: f32 }
DirectionalLight :: struct { color: [4]f32, position, direction: [3]f32, radius: f32 }
Light            :: union  { PointLight, SpotLight, DirectionalLight }

Particle :: struct {
  position: [3]f32, size: f32,
  velocity: [3]f32, size_end: f32,
  color_start, color_end, color: [4]f32,
  life, max_life, weight: f32,
  texture_index: u32,
}

Emitter :: struct {
  initial_velocity: [3]f32, size_start: f32,
  color_start, color_end:    [4]f32,
  aabb_min: [3]f32, emission_rate: f32,
  aabb_max: [3]f32, particle_lifetime: f32,
  position_spread, velocity_spread, time_accumulator: f32,
  size_end, weight, weight_spread: f32,
  texture_index, node_index: u32,
}

ForceField :: struct {
  tangent_strength, strength, area_of_effect: f32,
  node_index: u32,
}

CameraTarget :: struct {
  attachments: [AttachmentType][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  depth_pyramid: [FRAMES_IN_FLIGHT]depth_pyramid.DepthPyramid,
  draws:        [DrawPipeline]DrawBuffers,
  descriptor_set: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

CameraFrameConfig :: struct { index: u32, enabled_passes: PassTypeSet, enable_culling: bool }

ShadowMap     :: /* per-light 2D shadow buffers + draw cmds */
ShadowMapCube :: /* per-light cubemap shadow buffers + draw cmds */
```

### Constants

```odin
FRAMES_IN_FLIGHT      :: 2
MAX_NODES_IN_SCENE    :: 65536
MAX_ACTIVE_CAMERAS    :: 128
MAX_LIGHTS            :: 256
MAX_MESHES            :: 65536
MAX_MATERIALS         :: 4096
MAX_SPRITES           :: 4096
MAX_CAMERAS           :: 64
MAX_SHADOW_MAPS       :: 16
SHADOW_MAP_SIZE       :: 512
INVALID_SHADOW_INDEX  :: 0xFFFFFFFF
MAX_EMITTERS          :: 64
MAX_FORCE_FIELDS      :: 32
MAX_PARTICLES         :: 65536
```

## Sub-renderers

Every sub-renderer follows the same lifecycle pattern:

```odin
init     (self, gctx, ...layouts) -> vk.Result      // create pipeline + layout
setup    (self, gctx, ...) -> vk.Result             // optional: create swapchain-dependent resources
teardown (self, gctx, ...)                          // free swapchain-dependent resources
shutdown (self, gctx)                               // destroy pipeline + layout
record   (self, ...) (or render / simulate)         // record commands
```

Below is the per-sub-renderer surface. Push-constant struct layouts are
documented inline because the sizes are real Vulkan constraints (≤128 bytes).

### `geometry/` — G-buffer

```odin
Renderer :: struct { pipeline_layout: vk.PipelineLayout, pipeline: vk.Pipeline }

init     (self, gctx, camera_set_layout, textures_set_layout, bone_set_layout,
          material_set_layout, node_data_set_layout, mesh_data_set_layout,
          vertex_skinning_set_layout) -> vk.Result
setup    (self, gctx) -> vk.Result        // no-op
teardown (self, gctx)                      // no-op
shutdown (self, gctx)
record   (self, camera_handle, command_buffer, texture_manager,
          position_handle, normal_handle, albedo_handle, metallic_roughness_handle,
          emissive_handle, final_image_handle, depth_handle,
          ...descriptor_sets, vertex_buffer, index_buffer,
          draw_buffer, count_buffer, max_draws: u32)
```

Outputs: POSITION (R32G32B32A32_SFLOAT), NORMAL (R8G8B8A8_UNORM, encoded),
ALBEDO, METALLIC_ROUGHNESS, EMISSIVE.

### `direct_light/` — point/spot/directional

```odin
LightVolumeMesh :: struct {
  vertex_buffer: gpu.ImmutableBuffer(geometry.Vertex),
  index_buffer:  gpu.ImmutableBuffer(u32),
  index_count:   u32,
}

PointLightPushConstants :: struct {
  shadow_view_projection: matrix[4,4]f32,    // 64 B
  light_color:            [4]f32,            // 16 B
  position:               [3]f32, radius: f32,
  shadow_map_idx, scene_camera_idx: u32,
  position_texture_index, normal_texture_index,
  albedo_texture_index, metallic_texture_index: u32,
}

SpotLightPushConstants :: struct {
  shadow_view_projection: matrix[4,4]f32,
  light_color: [4]f32,
  position: [3]f32, angle_inner: f32,
  direction: [3]f32, radius: f32,
  angle_outer: f32,
  shadow_and_camera_indices:    u32,    // packed
  position_and_normal_indices:  u32,    // packed
  albedo_and_metallic_indices:  u32,    // packed
}                                       // total 128 B

DirectionalLightPushConstants :: struct {
  shadow_view_projection: matrix[4,4]f32,
  light_color: [4]f32,
  direction:   [3]f32,
  shadow_map_idx, scene_camera_idx: u32,
  position_texture_index, normal_texture_index,
  albedo_texture_index, metallic_texture_index: u32,
}

Renderer :: struct {
  point_pipeline, spot_pipeline, directional_pipeline: vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  sphere_mesh, cone_mesh, triangle_mesh: LightVolumeMesh,
}
```

```odin
init     (self, gctx, camera_set_layout, textures_set_layout) -> vk.Result
setup    (self, gctx) -> vk.Result
teardown (self, gctx)
shutdown (self, gctx)
begin_pass(self, final_image_handle, depth_handle, texture_manager, command_buffer, cameras_descriptor_set)
render_point_light      (self, camera_handle, ...textures, light_color, position, radius, shadow_map_idx, shadow_view_projection, command_buffer)
render_spot_light       (self, camera_handle, ...textures, light_color, position, direction, radius, angle_inner, angle_outer, shadow_map_idx, shadow_view_projection, command_buffer)
render_directional_light(self, camera_handle, ...textures, light_color, direction, shadow_map_idx, shadow_view_projection, command_buffer)
end_pass(command_buffer)
```

### `ambient/` — IBL

```odin
PushConstant :: struct {
  camera_index, environment_index, brdf_lut_index: u32,
  position_texture_index, normal_texture_index, albedo_texture_index,
  metallic_texture_index, emissive_texture_index: u32,
  environment_max_lod, ibl_intensity: f32,
}

Renderer :: struct {
  pipeline: vk.Pipeline, pipeline_layout: vk.PipelineLayout,
  environment_map: gpu.Texture2DHandle,
  brdf_lut:        gpu.Texture2DHandle,
  environment_max_lod, ibl_intensity: f32,
}
```

```odin
init     (self, gctx, camera_set_layout, textures_set_layout) -> vk.Result
setup    (self, gctx, texture_manager) -> vk.Result        // loads Cannon_Exterior.hdr + BRDF LUT
teardown (self, gctx, texture_manager)
shutdown (self, gctx)
record   (self, camera_handle, command_buffer, texture_manager, final_image_handle,
          cameras_descriptor_set, position_idx, normal_idx, albedo_idx, metallic_idx, emissive_idx)
```

### `shadow_render/` — 2D shadow

```odin
ShadowDepthPushConstants :: struct { view_projection: matrix[4,4]f32 }   // 64 B

System :: struct {
  max_draws, shadow_map_size: u32,
  depth_pipeline_layout: vk.PipelineLayout,
  depth_pipeline:        vk.Pipeline,
}

init    (self, gctx, ...layouts, max_draws: u32, shadow_map_size: u32) -> vk.Result
shutdown(self, gctx)
render  (self, command_buffer, texture_manager, view_projection, shadow_map: gpu.Texture2DHandle,
         draw_command, draw_count, ...descriptors, vertex_buffer, index_buffer, frame_index)
```

### `shadow_sphere_render/` — cubemap shadow

```odin
ShadowTransform :: struct {
  view, projection, view_projection: matrix[4,4]f32,
  near, far:       f32,
  frustum_planes:  [6][4]f32,
  position:        [3]f32,           // light position
}

ShadowDepthPushConstants :: struct {
  projection: matrix[4,4]f32,        // 64 B
  light_position: [3]f32, near_plane, far_plane: f32,   // total 84 B
}

System :: /* same shape as 2D shadow */
init    (self, gctx, ...layouts, max_draws, shadow_map_size: u32) -> vk.Result   // uses geometry shader
shutdown(self, gctx)
render  (self, command_buffer, texture_manager, projection, near, far, position,
         shadow_map: gpu.TextureCubeHandle, draw_command, draw_count, ...descriptors,
         vertex_buffer, index_buffer, frame_index)
```

### `occlusion_culling/` — frustum + Hi-Z

```odin
DrawPipeline :: enum { OPAQUE, TRANSPARENT, WIREFRAME, RANDOM_COLOR, LINE_STRIP, SPRITE }

DrawBuffers :: struct {
  count:    [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  commands: [FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
}

VisibilityPushConstants :: struct {
  camera_index, node_count, max_draws: u32,
  pyramid_width, pyramid_height: f32,
  depth_bias: f32,
  occlusion_enabled: u32,
}

CullingStats :: struct { opaque_draw_count, camera_index, frame_index: u32 }

System :: struct {
  cull_layout: vk.PipelineLayout, cull_pipeline: vk.Pipeline,
  depth_descriptor_layout: vk.DescriptorSetLayout,
  max_draws, node_count: u32,
  depth_bias: f32, stats_enabled: bool,
}

init    (self, gctx, max_draws: u32) -> vk.Result
shutdown(self, gctx)
stats   (self, opaque_draw_count, camera_index, frame_index) -> CullingStats
perform_culling(self, command_buffer, camera_index, frame_index,
                draws: ^[DrawPipeline]DrawBuffers,
                descriptor_set, pyramid_width, pyramid_height: u32)
```

### `shadow_culling/` — frustum cull per shadow caster

```odin
CullPushConstants :: struct {
  frustum_planes: [6][4]f32,
  node_count, max_draws, include_flags, exclude_flags: u32,
}

System :: struct {
  node_count, max_draws, include_flags, exclude_flags: u32,
  descriptor_layout: vk.DescriptorSetLayout,
  pipeline_layout:   vk.PipelineLayout,
  pipeline:          vk.Pipeline,
}

init    (self, gctx, max_draws, include_flags, exclude_flags: u32) -> vk.Result
shutdown(self, gctx)
create_per_light_descriptor(self, gctx, node_buffer, mesh_buffer, draw_count, draw_commands)
                          -> (vk.DescriptorSet, vk.Result)
execute (self, command_buffer, frustum_planes, shadow_draw_count_buffer, shadow_draw_count_ds)
```

### `shadow_sphere_culling/` — sphere cull for point-light shadows

```odin
SphereCullPushConstants :: struct {
  light_position: [3]f32, sphere_radius: f32,
  node_count, max_draws, include_flags, exclude_flags: u32,
}

System :: /* same shape as shadow_culling */
init    (self, gctx, max_draws, include_flags, exclude_flags: u32) -> vk.Result
shutdown(self, gctx)
create_per_light_descriptor(self, gctx, node_buffer, mesh_buffer, draw_count, draw_commands)
                          -> (vk.DescriptorSet, vk.Result)
execute (self, command_buffer, light_position, sphere_radius, shadow_draw_count_buffer, shadow_draw_count_ds)
```

### `depth_pyramid/` — Hi-Z

```odin
DepthReducePushConstants :: struct { current_mip: u32 }

DepthPyramid :: struct {
  texture: gpu.Texture2DHandle,
  views:        [MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
  full_view:    vk.ImageView,
  sampler:      vk.Sampler,
  mip_levels:   u32,
  using extent: vk.Extent2D,
}

System :: struct {
  depth_reduce_layout:    vk.PipelineLayout,
  depth_reduce_pipeline:  vk.Pipeline,
  depth_reduce_descriptor_layout: vk.DescriptorSetLayout,
  node_count: u32,
}

init             (self, gctx) -> vk.Result
shutdown         (self, gctx)
setup_pyramid    (gctx, pyramid: ^DepthPyramid, texture_manager, extent: vk.Extent2D) -> vk.Result
destroy_pyramid  (gctx, pyramid: ^DepthPyramid, texture_manager)
build_pyramid    (self, command_buffer, texture_manager, pyramid, base_depth: gpu.Texture2DHandle)
```

### `transparent/`

```odin
PushConstant :: struct { camera_index: u32 }
Renderer     :: struct { pipeline_layout: vk.PipelineLayout, pipeline: vk.Pipeline }

init     (self, gctx, ...layouts) -> vk.Result
setup    (self, gctx) -> vk.Result        // no-op
teardown (self, gctx)
shutdown (self, gctx)
record   (self, cmd, camera_index, ...descriptors, vertex_buffer, index_buffer,
          draw_buffer, count_buffer, max_draw_count: u32)
```

### `particles_compute/` & `particles_render/`

```odin
ParticleSystemParams :: struct {
  particle_count, emitter_count, forcefield_count: u32, delta_time: f32,
}

// particles_compute
Renderer :: struct {
  params_buffer, particle_count_buffer, particle_buffer,
  compact_particle_buffer: gpu.MutableBuffer(...),
  draw_command_buffer:     gpu.MutableBuffer(vk.DrawIndirectCommand),
  // emitter / compute / compact pipelines + descriptor layouts
}

init     (self, gctx, emitter_set_layout, forcefield_set_layout, node_data_set_layout) -> vk.Result
setup    (self, gctx, emitter_descriptor_set, forcefield_descriptor_set) -> vk.Result
teardown (self, gctx)
shutdown (self, gctx)
simulate (self, command_buffer, node_data_set)
compact  (self, command_buffer)
```

```odin
// particles_render
Renderer :: struct {
  render_pipeline_layout: vk.PipelineLayout,
  render_pipeline:        vk.Pipeline,
  default_texture_index:  u32,
}

init             (self, gctx, texture_manager, camera_set_layout, textures_set_layout) -> vk.Result
shutdown         (self, gctx)
create_render_pipeline(gctx, self, camera_set_layout, textures_set_layout) -> vk.Result
setup            (self, gctx) -> vk.Result
teardown         (self, gctx)
record           (self, cmd, camera_index, ...descriptors, particle_buffer, draw_command)
```

### `sprite/`

```odin
PushConstant :: struct { camera_index: u32 }
Renderer     :: struct { pipeline_layout: vk.PipelineLayout, pipeline: vk.Pipeline }

init   (self, gctx, camera_set_layout, textures_set_layout, node_data_set_layout, sprite_set_layout) -> vk.Result
setup    (self, gctx) -> vk.Result        // no-op
teardown (self, gctx)
shutdown (self, gctx)
record (self, cmd, camera_index, ...descriptors, vertex_buffer, index_buffer,
        draw_buffer, count_buffer, max_draw_count: u32)
```

### `wireframe/`, `line_strip/`, `random_color/`

Surface identical to `transparent/`:

```odin
PushConstant :: struct { camera_index: u32 }
Renderer     :: struct { pipeline_layout: vk.PipelineLayout, pipeline: vk.Pipeline }

init / setup / teardown / shutdown / record
```

Differs in topology (line, line-strip, triangle), shader, and blend state.

### `debug_bone/`

```odin
BoneInstance :: struct { position: [3]f32, scale: f32, color: [4]f32 }

Renderer :: struct {
  pipeline:        vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  instance_buffer: gpu.MutableBuffer(BoneInstance),
  max_bones:       u32,
  bone_instances:  [dynamic]BoneInstance,
}

init       (self, gctx, camera_set_layout) -> vk.Result
setup      (self, gctx) -> vk.Result
teardown   (self, gctx)
shutdown   (self, gctx)
stage_bones(self, instances: []BoneInstance)
clear_bones(self)
record     (self, cmd, camera_index, camera_set)
```

### `post_process/`

```odin
PostProcessEffectType :: enum int {
  GRAYSCALE, TONEMAP, BLUR, BLOOM, OUTLINE, FOG, CROSSHATCH, DOF, NONE,
}

GrayscaleEffect  :: struct { weights: [3]f32, strength: f32 }
ToneMapEffect    :: struct { exposure, gamma: f32, padding: [2]f32 }
BlurEffect       :: struct { radius, direction, weight_falloff, padding: f32 }   // direction: 0=H, 1=V; weight_falloff: 0=box, 1=gaussian
BloomEffect      :: struct { threshold, intensity, blur_radius, direction: f32 }
OutlineEffect    :: struct { color: [3]f32, thickness: f32 }
FogEffect        :: struct { color: [3]f32, density, start, end: f32 }
CrossHatchEffect :: struct { resolution: [2]f32, hatch_offset_y, lum_threshold_01, lum_threshold_02, lum_threshold_03, lum_threshold_04, padding: f32 }
DoFEffect        :: struct { focus_distance, focus_range, blur_strength, bokeh_intensity: f32 }

PostprocessEffect :: union {
  GrayscaleEffect, ToneMapEffect, BlurEffect, BloomEffect,
  OutlineEffect, FogEffect, CrossHatchEffect, DoFEffect,
}

Renderer :: struct {
  pipelines:        [len(PostProcessEffectType)]vk.Pipeline,
  pipeline_layouts: [len(PostProcessEffectType)]vk.PipelineLayout,
  effect_stack:     [dynamic]PostprocessEffect,
  images:           [2]gpu.Texture2DHandle,                 // ping-pong
}

get_effect_type(effect: PostprocessEffect) -> PostProcessEffectType
add_effect    (self, effect: PostprocessEffect)
clear_effects (self)

init     (self, gctx, color_format, textures_set_layout) -> vk.Result
setup    (self, gctx, texture_manager, extent) -> vk.Result
teardown (self, gctx, texture_manager)
shutdown (self, gctx)
record   (self, cmd, texture_manager, input_image, output_image, output_view,
          extent, textures_descriptor_set,
          position_idx, normal_idx, albedo_idx, metallic_idx, emissive_idx, depth_idx)
```

### `ui/` (widget renderer)

```odin
DrawBatch       :: struct { first_index, index_count: u32 }
CommandSortKey  :: struct { z_order: i32, texture_id: u32, cmd_index: int }

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout, pipeline: vk.Pipeline,
  vertex_buffers: [FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex2D),
  index_buffers:  [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  vertices:       [UI_MAX_VERTICES]Vertex2D,
  indices:        [UI_MAX_INDICES]u32,
  vertex_count, index_count: u32,
  commands:       [dynamic]cmd.RenderCommand,
}

init           (self, gctx, textures_set_layout, format: vk.Format) -> vk.Result
stage_commands (self, commands: []cmd.RenderCommand)
setup          (self, gctx) -> vk.Result
teardown       (self, gctx)
create_pipeline(self, gctx, format: vk.Format) -> vk.Result
shutdown       (self, gctx)
render         (self, cmd, frame_index, extent, textures_descriptor_set)
```

### `debug_ui/` (microui)

```odin
UI_MAX_QUAD     :: 1000
UI_MAX_VERTICES :: UI_MAX_QUAD * 4
UI_MAX_INDICES  :: UI_MAX_QUAD * 6

Renderer :: struct {
  ctx:             mu.Context,
  pipeline_layout: vk.PipelineLayout, pipeline: vk.Pipeline,
  atlas_handle:    gpu.Texture2DHandle,
  projection:      matrix[4, 4]f32,
  vertex_buffer:   gpu.MutableBuffer(Vertex2D),
  index_buffer:    gpu.MutableBuffer(u32),
  vertex_count, index_count: u32,
  vertices: [UI_MAX_VERTICES]Vertex2D,
  indices:  [UI_MAX_INDICES]u32,
  frame:           vk.Extent2D,
  dpi_scale:       f32,
  current_scissor: vk.Rect2D,
}

init           (self, gctx, color_format, extent, dpi_scale=1, textures_set_layout) -> vk.Result
setup          (self, gctx, texture_manager) -> vk.Result
teardown       (self, gctx)
ui_flush       (self, cmd, frame_index, textures_set)
ui_push_quad   (self, rect: vk.Rect2D, color: [4]f32)
ui_draw_rect   (self, x, y, w, h: i32, color: [4]f32)
ui_draw_text   (self, x, y: i32, text: string, color: [4]f32)
ui_draw_icon   (self, x, y: i32, texture_index: u32)
ui_set_clip_rect(self, rect: vk.Rect2D)
shutdown       (self, gctx)
recreate_images(self, gctx, texture_manager, extent) -> vk.Result
record         (self, cmd, swapchain_view, extent, textures_descriptor_set)
```

### `shared/` — specialization constants

```odin
SamplerType :: enum u32 {
  NEAREST_CLAMP = 0, LINEAR_CLAMP = 1,
  NEAREST_REPEAT = 2, LINEAR_REPEAT = 3,
}

Constants :: struct {
  max_textures, max_cube_textures: u32,
  sampler_nearest_clamp, sampler_linear_clamp,
  sampler_nearest_repeat, sampler_linear_repeat: u32,
  light_kind_point, light_kind_directional, light_kind_spot: u32,
}

SHADER_SPEC_CONSTANTS: vk.SpecializationInfo  // bound at pipeline create time
```

## Pass-by-pass summary

| Subsystem | Entry point | Role | Pass tag |
|---|---|---|---|
| Geometry | `geometry.Renderer.record` | G-buffer | `GEOMETRY` |
| Direct light | `direct_light.Renderer.render_*` | Point/spot/directional | `LIGHTING` |
| Ambient/IBL | `ambient.Renderer.record` | Image-based lighting | `LIGHTING` |
| Shadow 2D | `shadow_render.System.render` | Directional/spot shadow depth | `SHADOW` |
| Shadow cube | `shadow_sphere_render.System.render` | Point shadow depth | `SHADOW` |
| Shadow culling | `shadow_culling.System.execute` | Frustum cull per shadow | (compute) |
| Sphere culling | `shadow_sphere_culling.System.execute` | Sphere cull per point shadow | (compute) |
| Occlusion | `occlusion_culling.System.perform_culling` | Frustum + Hi-Z | (compute) |
| Depth pyramid | `depth_pyramid.System.build_pyramid` | Hi-Z reduction | (compute) |
| Particles sim | `particles_compute.Renderer.simulate` | Emit + simulate + compact | (compute) |
| Particles draw | `particles_render.Renderer.record` | Point sprites | `PARTICLES` |
| Transparency | `transparent.Renderer.record` | Alpha blend | `TRANSPARENCY` |
| Sprite | `sprite.Renderer.record` | Billboards | `SPRITE` |
| Wireframe | `wireframe.Renderer.record` | Edges | `WIREFRAME` |
| Line strip | `line_strip.Renderer.record` | Polylines | `LINE_STRIP` |
| Random color | `random_color.Renderer.record` | Debug | `RANDOM_COLOR` |
| Debug bone | `debug_bone.Renderer.record` | Skeleton viz | `DEBUG_BONE` |
| Post-process | `post_process.Renderer.record` | Effect stack | `POST_PROCESS` |
| UI | `ui.Renderer.render` | Widget rendering | `UI` |
| Debug UI | `debug_ui.Renderer.record` | microui overlay | `DEBUG_UI` |
