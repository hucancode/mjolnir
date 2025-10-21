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
  using data:    LightData,
  node_handle:   Handle, // Associated scene node for transform updates
  camera_handle: Handle, // Camera (regular or spherical based on light type)
}

create_light :: proc(
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
  light_type: LightType,
  node_handle: Handle,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle_inner: f32 = math.PI * 0.16,
  angle_outer: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> (
  Handle,
  bool,
) {
  handle, light, ok := alloc(&manager.lights)
  if !ok {
    log.error("Failed to allocate light: pool capacity reached")
    return Handle{}, false
  }

  light.type = light_type
  light.node_handle = node_handle
  light.cast_shadow = cast_shadow
  light.color = color
  light.radius = radius
  light.angle_inner = angle_inner
  light.angle_outer = angle_outer
  light.node_index = node_handle.index
  light.camera_handle = {}
  light.camera_index = 0xFFFFFFFF
  light.shadow_map = 0xFFFFFFFF

  if cast_shadow {
    #partial switch light_type {
    case .POINT:
      // Point lights use spherical cameras for omnidirectional shadows
      cam_handle, spherical_cam, cam_ok := alloc(&manager.spherical_cameras)
      if !cam_ok {
        log.error("Failed to allocate spherical camera for point light")
        free(&manager.lights, handle)
        return Handle{}, false
      }

      init_result := spherical_camera_init(
        spherical_cam,
        gctx,
        manager,
        SHADOW_MAP_SIZE,
        {0, 0, 0}, // center will be updated from light node
        radius,
        0.1, // near
        radius, // far
        .D32_SFLOAT,
        MAX_NODES_IN_SCENE,
      )

      if init_result != .SUCCESS {
        log.error("Failed to initialize spherical camera for point light")
        free(&manager.spherical_cameras, cam_handle)
        free(&manager.lights, handle)
        return Handle{}, false
      }

      light.camera_handle = cam_handle
      light.camera_index = cam_handle.index
      light.shadow_map = spherical_cam.depth_cube.index

    case .DIRECTIONAL, .SPOT:
      // Directional and spot lights use regular cameras
      cam_handle, cam, cam_ok := alloc(&manager.cameras)
      if !cam_ok {
        log.error("Failed to allocate camera for directional/spot light")
        free(&manager.lights, handle)
        return Handle{}, false
      }

      // Camera parameters differ by light type
      fov := f32(math.PI * 0.5) // 90 degrees default
      if light_type == .SPOT {
        fov = angle_outer * 2.0 // FOV should cover the spot cone
      }

      init_result := camera_init(
        cam,
        gctx,
        manager,
        SHADOW_MAP_SIZE,
        SHADOW_MAP_SIZE,
        .R8G8B8A8_UNORM, // color format (not used for shadow-only camera)
        .D32_SFLOAT, // depth format
        {.SHADOW}, // only shadow pass enabled
        {0, 0, 0}, // position will be updated from light node
        {0, -1, 0}, // looking down by default
        fov,
        radius * 0.01, // near plane as 1% of radius
        radius, // far
      )

      if init_result != .SUCCESS {
        log.error("Failed to initialize camera for directional/spot light")
        free(&manager.cameras, cam_handle)
        free(&manager.lights, handle)
        return Handle{}, false
      }

      light.camera_handle = cam_handle
      light.camera_index = cam_handle.index
      // Use camera's shared depth texture for shadow map
      light.shadow_map = camera_get_attachment(cam, .DEPTH, 0).index
      log.infof(
        "Created %v light - shadow_map texture index=%d, camera_index=%d",
        light_type,
        light.shadow_map,
        light.camera_index,
      )
    }
  }

  gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  return handle, true
}

// Destroy a light handle
destroy_light :: proc(
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
  handle: Handle,
) -> bool {
  light, light_ok := get(manager.lights, handle)
  if !light_ok {
    return false
  }

  // Destroy associated camera if it exists (switch on light type to determine pool)
  if light.camera_handle.generation > 0 {
    #partial switch light.type {
    case .POINT:
      // Point lights use spherical cameras
      if cam, cam_ok := get(manager.spherical_cameras, light.camera_handle);
         cam_ok {
        spherical_camera_destroy(cam, gctx.device, gctx.command_pool, manager)
      }
      free(&manager.spherical_cameras, light.camera_handle)

    case .DIRECTIONAL, .SPOT:
      // Directional and spot lights use regular cameras
      if cam, cam_ok := get(manager.cameras, light.camera_handle); cam_ok {
        camera_destroy(cam, gctx.device, gctx.command_pool, manager)
      }
      free(&manager.cameras, light.camera_handle)
    }
  }

  _, freed := free(&manager.lights, handle)
  return freed
}

update_light_gpu_data :: proc(manager: ^Manager, handle: Handle) {
  if light, ok := get(manager.lights, handle); ok {
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}
update_light_shadow_camera_transforms :: proc(
  manager: ^Manager,
  frame_index: u32 = 0,
) {
  for &entry, light_index in manager.lights.entries do if entry.active {
    light := &entry.item
    if !light.cast_shadow do continue
    if light.camera_handle.generation == 0 do continue
    // Get light's world transform from node
    node_data := gpu.mutable_buffer_get(&manager.node_data_buffer, light.node_index)
    if node_data == nil do continue
    world_matrix := gpu.mutable_buffer_get(&manager.world_matrix_buffer, light.node_index)
    if world_matrix == nil do continue
    // Extract position and direction from world matrix
    light_position := world_matrix[3].xyz
    light_direction := world_matrix[2].xyz
    #partial switch light.type {
    case .POINT:
      // Point lights use spherical cameras
      spherical_cam := get(manager.spherical_cameras, light.camera_handle)
      if spherical_cam != nil {
        spherical_cam.center = light_position
        light.shadow_map = spherical_cam.depth_cube.index
      }
    case .DIRECTIONAL:
      // TODO: Implement directional light later
      cam := get(manager.cameras, light.camera_handle)
      if cam != nil {
        camera_position := light_position - light_direction * 50.0 // Far back
        target_position := light_position
        camera_look_at(cam, camera_position, target_position)
        light.shadow_map = camera_get_attachment(cam, .DEPTH, frame_index).index
      }
    case .SPOT:
      cam := get(manager.cameras, light.camera_handle)
      if cam != nil {
        target_position := light_position + light_direction
        camera_look_at(cam, light_position, target_position)
        light.shadow_map = camera_get_attachment(cam, .DEPTH, frame_index).index
      }
    }
    gpu.write(&manager.lights_buffer, &light.data, light_index)
  }
}
