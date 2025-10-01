package resources

import "../geometry"
import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

LightType :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

LightData :: struct {
  color:        [4]f32, // RGB + intensity
  radius:       f32, // range for point/spot lights
  angle_inner:  f32, // inner cone angle for spot lights
  angle_outer:  f32, // outer cone angle for spot lights
  type:         LightType, // LightType
  node_index:   u32, // index into world matrices buffer
  shadow_map:   u32, // texture index in bindless array
  camera_index: u32, // index into camera matrices buffer
  cast_shadow:  b32, // 0 = no shadow, 1 = cast shadow
}

Light :: struct {
  using data:           LightData,
  node_handle:          Handle, // Associated scene node for transform updates
  // For spot lights - single render target for shadow mapping
  shadow_render_target: Handle,
  // For point lights - 6 render targets for cube shadow mapping
  cube_render_targets:  [6]Handle,
}

// Create a new light and return its handle
create_light :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  light_type: LightType,
  node_handle: Handle,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle_inner: f32 = math.PI * 0.16,
  angle_outer: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> Handle {
  handle, light := alloc(&manager.lights)
  light.type = light_type
  light.node_handle = node_handle
  light.cast_shadow = cast_shadow
  light.color = color
  light.radius = radius
  light.angle_inner = angle_inner
  light.angle_outer = angle_outer
  light.cast_shadow = b32(cast_shadow)
  light.node_index = node_handle.index
  if cast_shadow {
    setup_light_shadow_resources(manager, gpu_context, handle, light)
  }
  gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  return handle
}

// Destroy a light handle
destroy_light :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  handle: Handle,
) -> bool {
  light, ok := get(manager.lights, handle)
  if !ok do return false
  // Destroy shadow resources
  destroy_light_shadow_resources(manager, gpu_context, light)
  _, freed := free(&manager.lights, handle)
  return freed
}

// Get a light by handle
get_light :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^Light,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.lights, handle)
  return
}

// Update light color and intensity
set_light_color :: proc(
  manager: ^Manager,
  handle: Handle,
  color: [3]f32,
  intensity: f32,
) {
  if light, ok := get(manager.lights, handle); ok {
    light.color = {color.x, color.y, color.z, intensity}
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}

// Update light radius for point/spot lights
set_light_radius :: proc(manager: ^Manager, handle: Handle, radius: f32) {
  if light, ok := get(manager.lights, handle); ok {
    light.radius = radius
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}

// Update spot light angles
set_spot_light_angles :: proc(
  manager: ^Manager,
  handle: Handle,
  inner_angle: f32,
  outer_angle: f32,
) {
  if light, ok := get(manager.lights, handle); ok {
    light.angle_inner = inner_angle
    light.angle_outer = outer_angle
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}

// Enable/disable shadow casting
set_light_cast_shadow :: proc(
  manager: ^Manager,
  handle: Handle,
  cast_shadow: b32,
) {
  if light, ok := get(manager.lights, handle); ok {
    light.cast_shadow = cast_shadow
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}

// Set shadow render target for spot lights
set_spot_light_shadow_render_target :: proc(
  manager: ^Manager,
  light_handle: Handle,
  render_target_handle: Handle,
) {
  if light, ok := get(manager.lights, light_handle); ok {
    light.shadow_render_target = render_target_handle
    if rt, ok := get(manager.render_targets, render_target_handle); ok {
      light.camera_index = rt.camera.index
    }
  }
}

// Set cube render targets for point lights (one for each face)
set_point_light_cube_render_targets :: proc(
  manager: ^Manager,
  light_handle: Handle,
  render_targets: [6]Handle,
) {
  if light, ok := get(manager.lights, light_handle); ok {
    light.cube_render_targets = render_targets
  }
}

// Update shadow camera positions for lights that cast shadows
update_shadow_camera_transforms :: proc(self: ^Manager) {
  // Iterate through all lights to update shadow cameras
  for idx in 0 ..< len(self.lights.entries) {
    entry := &self.lights.entries[idx]
    if entry.generation > 0 && entry.active {
      light := &entry.item
      // Skip if not enabled or not casting shadow
      if !light.cast_shadow do continue
      switch light.type {
      case .POINT:
        update_point_light_shadow_cameras(self, light)
      case .SPOT:
        update_spot_light_shadow_cameras(self, light)
      case .DIRECTIONAL:
        update_directional_light_shadow_cameras(self, light)
      }
    }
  }
}

update_point_light_shadow_cameras :: proc(self: ^Manager, light: ^Light) {
  // Point light cube face directions: forward=-Z convention
  // +X, -X, +Y, -Y, +Z, -Z faces
  dirs := [6][3]f32 {
    {1, 0, 0},
    {-1, 0, 0},
    {0, 1, 0},
    {0, -1, 0},
    {0, 0, 1},
    {0, 0, -1},
  }
  // Up vectors for each face with forward=-Z convention
  ups := [6][3]f32 {
    {0, -1, 0},
    {0, -1, 0},
    {0, 0, 1},
    {0, 0, -1},
    {0, -1, 0},
    {0, -1, 0},
  }
  world_matrix := gpu.staged_buffer_get(
    &self.world_matrix_buffer,
    light.node_handle.index,
  )
  position := world_matrix[3].xyz
  // Update cameras for each cube face
  for face in 0 ..< 6 {
    if light.cube_render_targets[face].generation == 0 do continue
    render_target, ok := get(
      self.render_targets,
      light.cube_render_targets[face],
    )
    if !ok do continue
    camera, camera_ok := get(self.cameras, render_target.camera)
    if !camera_ok do continue
    target := position + dirs[face]
    geometry.camera_look_at(camera, position, target, ups[face])
    render_target_upload_camera_data(self, render_target)
  }
}

update_spot_light_shadow_cameras :: proc(self: ^Manager, light: ^Light) {
  if light.shadow_render_target.generation == 0 do return
  render_target, ok := get(self.render_targets, light.shadow_render_target)
  if !ok do return
  camera, camera_ok := get(self.cameras, render_target.camera)
  if !camera_ok do return
  world_matrix := gpu.staged_buffer_get(
    &self.world_matrix_buffer,
    light.node_handle.index,
  )
  position := world_matrix[3].xyz
  // Extract forward direction: -Z axis from world matrix (forward=-Z convention)
  forward := world_matrix[2].xyz // Light's actual forward direction from matrix
  target := position + forward
  up := [3]f32{0, 1, 0}
  if linalg.abs(linalg.dot(forward, up)) > 0.99 {
    up = {1, 0, 0}
  }
  geometry.camera_look_at(camera, position, target, up)
  // log.debugf("Spot light %v shadow camera %v updated to %v", light, render_target.camera, camera)
  render_target_upload_camera_data(self, render_target)
}

// Setup shadow resources for a light (called during light creation)
setup_light_shadow_resources :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  light_handle: Handle,
  light: ^Light,
) {
  switch light.type {
  case .POINT:
    setup_point_light_shadow_resources(
      manager,
      gpu_context,
      light_handle,
      light,
    )
  case .SPOT:
    setup_spot_light_shadow_resources(
      manager,
      gpu_context,
      light_handle,
      light,
    )
  case .DIRECTIONAL:
    setup_directional_light_shadow_resources(
      manager,
      gpu_context,
      light_handle,
      light,
    )
  }
}

// Setup shadow resources for point lights
setup_point_light_shadow_resources :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  light_handle: Handle,
  light: ^Light,
) {
  // Create cube shadow map texture
  cube_shadow_handle, _, ret := create_empty_texture_cube(
    gpu_context,
    manager,
    SHADOW_MAP_SIZE,
    .D32_SFLOAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  )
  if ret != .SUCCESS {
    log.errorf("Failed to create cube shadow texture: %v", ret)
    return
  }
  light.shadow_map = cube_shadow_handle.index

  // Setup 6 render targets for cube faces (forward=-Z convention)
  // +X, -X, +Y, -Y, +Z, -Z faces
  dirs := [6][3]f32 {
    {1, 0, 0},
    {-1, 0, 0},
    {0, 1, 0},
    {0, -1, 0},
    {0, 0, 1},
    {0, 0, -1},
  }
  // Up vectors for each face with forward=-Z convention
  ups := [6][3]f32 {
    {0, -1, 0},
    {0, -1, 0},
    {0, 0, 1},
    {0, 0, -1},
    {0, -1, 0},
    {0, -1, 0},
  }

  for face in 0 ..< 6 {
    // Create render target for this face
    render_target_handle, render_target := alloc(&manager.render_targets)

    // Create camera for this face
    camera_handle, camera := alloc(&manager.cameras)
    camera^ = geometry.make_camera_perspective(
      math.PI * 0.5,
      1.0,
      0.1,
      light.radius,
    )

    render_target.camera = camera_handle
    render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
    render_target.features = {.DEPTH_TEXTURE}

    // Set depth texture for all frames to the cube shadow map
    for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
      render_target.depth_textures[frame_idx] = cube_shadow_handle
    }

    light.cube_render_targets[face] = render_target_handle
  }
}

// Setup shadow resources for spot lights
setup_spot_light_shadow_resources :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  light_handle: Handle,
  light: ^Light,
) {
  // Create shadow map texture
  shadow_handle, _, ret := create_empty_texture_2d(
    gpu_context,
    manager,
    SHADOW_MAP_SIZE,
    SHADOW_MAP_SIZE,
    .D32_SFLOAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  )
  if ret != .SUCCESS {
    log.errorf("Failed to create shadow texture")
    return
  }
  light.shadow_map = shadow_handle.index

  // Create render target
  render_target_handle, render_target := alloc(&manager.render_targets)

  // Create camera
  camera_handle, camera := alloc(&manager.cameras)
  fov := light.angle_outer * 2.0
  camera^ = geometry.make_camera_perspective(fov, 1.0, 0.1, light.radius)

  render_target.camera = camera_handle
  render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
  render_target.features = {.DEPTH_TEXTURE}

  // Set depth texture for all frames
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    render_target.depth_textures[frame_idx] = shadow_handle
  }

  light.shadow_render_target = render_target_handle
  light.camera_index = camera_handle.index
}

// Setup shadow resources for directional lights
setup_directional_light_shadow_resources :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  light_handle: Handle,
  light: ^Light,
) {
  shadow_handle, _, ret := create_empty_texture_2d(
    gpu_context,
    manager,
    SHADOW_MAP_SIZE,
    SHADOW_MAP_SIZE,
    .D32_SFLOAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  )
  if ret != .SUCCESS {
    log.errorf("Failed to create directional shadow texture")
    return
  }
  light.shadow_map = shadow_handle.index

  // Create render target
  render_target_handle, render_target := alloc(&manager.render_targets)

  // Create orthographic camera for directional light
  camera_handle, camera := alloc(&manager.cameras)
  ortho_size: f32 = 100.0
  camera^ = geometry.make_camera_ortho(ortho_size, ortho_size, 0.1, 100.0)

  render_target.camera = camera_handle
  render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
  render_target.features = {.DEPTH_TEXTURE}

  // Set depth texture for all frames
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    render_target.depth_textures[frame_idx] = shadow_handle
  }

  light.shadow_render_target = render_target_handle
  light.camera_index = camera_handle.index
}

// Fit orthographic camera bounds to contain scene geometry
fit_shadow_camera_to_scene :: proc(
  camera: ^geometry.Camera,
  light_dir: [3]f32,
  scene_center: [3]f32 = {0, 0, 0},
  scene_radius: f32 = 50.0,
) {
  // Calculate orthographic bounds that contain a sphere around scene center
  // This ensures all geometry within scene_radius gets shadows
  ortho_size := scene_radius * 1.5 // Add padding

  switch &proj in camera.projection {
  case geometry.PerspectiveProjection:
    // Should not happen for directional lights
    log.error("Directional light has perspective projection!")
  case geometry.OrthographicProjection:
    proj.width = ortho_size
    proj.height = ortho_size
    proj.near = 0.1
    proj.far = scene_radius * 3.0 // Enough to contain scene depth
  }
}

update_directional_light_shadow_cameras :: proc(self: ^Manager, light: ^Light) {
  if light.shadow_render_target.generation == 0 do return
  render_target, ok := get(self.render_targets, light.shadow_render_target)
  if !ok do return
  camera, camera_ok := get(self.cameras, render_target.camera)
  if !camera_ok do return

  // Get light direction from world matrix
  world_matrix := gpu.staged_buffer_get(
    &self.world_matrix_buffer,
    light.node_handle.index,
  )
  light_dir := linalg.normalize(world_matrix[2].xyz) // Forward direction

  // Simple approach: Cover a fixed area around scene origin
  // For better quality, implement CSM or fit to main camera frustum
  scene_center := [3]f32{0, 0, 0}
  scene_radius: f32 = 50.0

  // Fit the orthographic camera to cover the scene
  fit_shadow_camera_to_scene(camera, light_dir, scene_center, scene_radius)

  // Position shadow camera far back along light direction
  shadow_distance := scene_radius * 2.0
  position := scene_center - light_dir * shadow_distance
  target := scene_center

  up := [3]f32{0, 1, 0}
  if linalg.abs(linalg.dot(light_dir, up)) > 0.99 {
    up = {1, 0, 0}
  }

  geometry.camera_look_at(camera, position, target, up)
  render_target_upload_camera_data(self, render_target)
}

// Destroy shadow resources for a light
destroy_light_shadow_resources :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  light: ^Light,
) {
  if !light.cast_shadow do return
  switch light.type {
  case .POINT:
    // Get the cube shadow texture handle before destroying render targets
    cube_texture_handle: Handle
    if light.cube_render_targets[0].generation != 0 {
      if render_target, ok := get(
        manager.render_targets,
        light.cube_render_targets[0],
      ); ok {
        if len(render_target.depth_textures) > 0 {
          cube_texture_handle = render_target.depth_textures[0]
        }
      }
    }

    // Destroy cube render targets and their cameras
    for face in 0 ..< 6 {
      if light.cube_render_targets[face].generation != 0 {
        if render_target, ok := free(
          &manager.render_targets,
          light.cube_render_targets[face],
        ); ok {
          // Free the camera associated with this render target
          free(&manager.cameras, render_target.camera)
        }
        light.cube_render_targets[face] = {}
      }
    }
    // Free the cube shadow map texture
    if cube_texture_handle.generation != 0 {
      if texture, ok := free(&manager.image_cube_buffers, cube_texture_handle);
         ok {
        gpu.cube_depth_texture_destroy(gpu_context.device, texture)
      }
    }
  case .SPOT:
    // Get the shadow texture handle before destroying render target
    shadow_texture_handle: Handle
    if light.shadow_render_target.generation != 0 {
      if render_target, ok := get(
        manager.render_targets,
        light.shadow_render_target,
      ); ok {
        if len(render_target.depth_textures) > 0 {
          shadow_texture_handle = render_target.depth_textures[0]
        }
      }
    }

    // Destroy spot render target and camera
    if light.shadow_render_target.generation != 0 {
      if render_target, ok := free(
        &manager.render_targets,
        light.shadow_render_target,
      ); ok {
        // Free the camera associated with this render target
        free(&manager.cameras, render_target.camera)
      }
      light.shadow_render_target = {}
    }
    // Free the shadow map texture
    if shadow_texture_handle.generation != 0 {
      if texture, ok := free(&manager.image_2d_buffers, shadow_texture_handle);
         ok {
        gpu.image_buffer_destroy(gpu_context.device, texture)
      }
    }
  case .DIRECTIONAL:
    // Destroy directional render target and camera
    if light.shadow_render_target.generation != 0 {
      if render_target, ok := free(
        &manager.render_targets,
        light.shadow_render_target,
      ); ok {
        // Free the camera associated with this render target
        free(&manager.cameras, render_target.camera)
      }
      light.shadow_render_target = {}
    }
    // Free the shadow map texture
    shadow_texture_handle: Handle
    if light.shadow_render_target.generation != 0 {
      if render_target, ok := get(
        manager.render_targets,
        light.shadow_render_target,
      ); ok {
        if len(render_target.depth_textures) > 0 {
          shadow_texture_handle = render_target.depth_textures[0]
        }
      }
    }
    if shadow_texture_handle.generation != 0 {
      if texture, ok := free(&manager.image_2d_buffers, shadow_texture_handle);
         ok {
        gpu.image_buffer_destroy(gpu_context.device, texture)
      }
    }
  }

  light.shadow_map = 0
}
