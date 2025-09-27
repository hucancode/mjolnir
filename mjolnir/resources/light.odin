package resources

import "../gpu"

LightKind :: enum u32 {
  POINT,
  DIRECTIONAL,
  SPOT,
}

LightShadowResources :: struct {
  render_target:       Handle,
  cube_render_targets: [6]Handle,
  camera:              Handle,
  cube_cameras:        [6]Handle,
  shadow_map:          Handle,
}

LightData :: struct {
  color:               [4]f32,
  position:            [4]f32,
  direction:           [4]f32,
  radius:              f32,
  angle:               f32,
  intensity:           f32,
  padding:             f32,
  type:                u32,
  shadow_map:          u32,
  light_camera_index:  u32,
  enabled:             b32,
  cast_shadow:         b32,
  cube_camera_indices: [6]u32,
}

Light :: struct {
  kind:        LightKind,
  color:       [4]f32,
  radius:      f32,
  angle:       f32,
  cast_shadow: bool,
  enabled:     bool,
  node_handle: Handle,
  position:    [3]f32,
  direction:   [3]f32,
  shadow:      LightShadowResources,
}

update_light_gpu_data :: proc(manager: ^Manager, handle: Handle) {
  if handle.index >= MAX_LIGHTS {
    return
  }
  light := get(manager.lights, handle)
  if light == nil {
    return
  }
  gpu_data := LightData {
    color               = light.color,
    position            = [4]f32{light.position.x, light.position.y, light.position.z, 1.0},
    direction           = [4]f32{light.direction.x, light.direction.y, light.direction.z, 0.0},
    radius              = light.radius,
    angle               = light.angle,
    intensity           = light.color.w,
    padding             = 0.0,
    type                = cast(u32)light.kind,
    shadow_map          = light.shadow.shadow_map.index,
    light_camera_index  = light.shadow.camera.index,
    enabled             = cast(b32)light.enabled,
    cast_shadow         = cast(b32)light.cast_shadow,
    cube_camera_indices = {},
  }
  for i in 0 ..< len(gpu_data.cube_camera_indices) {
    gpu_data.cube_camera_indices[i] = light.shadow.cube_cameras[i].index
  }
  gpu.staged_buffer_write(
    &manager.lights_buffer,
    &gpu_data,
    int(handle.index),
  )
}
