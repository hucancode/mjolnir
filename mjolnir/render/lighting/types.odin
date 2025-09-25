package lighting

import "core:math/linalg"
import resources "../../resources"
import vk "vendor:vulkan"

LightKind :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

LightPushConstant :: struct {
  scene_camera_idx:       u32,
  light_camera_idx:       u32, // for shadow mapping
  shadow_map_id:          u32,
  light_kind:             LightKind,
  light_color:            [3]f32,
  light_angle:            f32,
  light_position:         [3]f32,
  light_radius:           f32,
  light_direction:        [3]f32,
  light_cast_shadow:      b32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  input_image_index:      u32,
}

ShadowResources :: struct {
  cube_render_targets: [6]resources.Handle,
  cube_cameras:        [6]resources.Handle,
  shadow_map:          resources.Handle,
  render_target:       resources.Handle,
  camera:              resources.Handle,
}

LightInfo :: struct {
  using gpu_data:         LightPushConstant,
  node_handle:            resources.Handle,
  transform_generation:   u64,
  using shadow_resources: ShadowResources,
  dirty:                  bool,
}
