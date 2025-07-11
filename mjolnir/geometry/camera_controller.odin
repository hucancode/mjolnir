package geometry

import "core:log"
import "core:math"
import linalg "core:math/linalg"
import glfw "vendor:glfw"

CameraControllerType :: enum {
  ORBIT,
  FREE,
  FOLLOW,
  CINEMATIC,
}

// Orbit camera controller data
OrbitCameraData :: struct {
  target:       [3]f32,
  distance:     f32,
  yaw:          f32,
  pitch:        f32,
  min_distance: f32,
  max_distance: f32,
  min_pitch:    f32,
  max_pitch:    f32,
  zoom_speed:   f32,
  rotate_speed: f32,
}

// Free camera controller data
FreeCameraData :: struct {
  move_speed:       f32,
  rotation_speed:   f32,
  boost_multiplier: f32,
  mouse_sensitivity: f32,
}

// Follow camera controller data (for future use)
FollowCameraData :: struct {
  target:       ^[3]f32,  // Pointer to target position
  offset:       [3]f32,
  follow_speed: f32,
  look_at_target: bool,
}

// Base controller structure with self-contained input
CameraController :: struct {
  type: CameraControllerType,
  window: glfw.WindowHandle,  // Controller owns window for input
  data: union {
    OrbitCameraData,
    FreeCameraData,
    FollowCameraData,
  },
  // Internal input state (private to controller)
  last_mouse_pos: [2]f64,
  mouse_delta: [2]f64,
  scroll_delta: f32,
}

// Global scroll state for handling GLFW callbacks
@(private="file")
g_scroll_deltas: map[glfw.WindowHandle]f32

// Helper to setup scroll callbacks (called once during controller setup)
setup_camera_controller_callbacks :: proc(window: glfw.WindowHandle) {
  glfw.SetScrollCallback(window, proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
    context = {}  // GLFW callback context
    g_scroll_deltas[window] = f32(yoffset)
  })
}

// Helper function for controllers to get and consume scroll delta
get_scroll_delta_for_window :: proc(window: glfw.WindowHandle) -> f32 {
  delta := g_scroll_deltas[window]
  g_scroll_deltas[window] = 0  // Reset after reading
  return delta
}

// Helper to clamp values
clamp :: proc(value, min_val, max_val: f32) -> f32 {
  if value < min_val do return min_val
  if value > max_val do return max_val
  return value
}

// Orbit controller initialization
camera_controller_orbit_init :: proc(
  window: glfw.WindowHandle,
  target: [3]f32,
  distance: f32,
  yaw := f32(0),
  pitch := f32(0),
) -> CameraController {
  return CameraController{
    type = .ORBIT,
    window = window,
    data = OrbitCameraData{
      target = target,
      distance = distance,
      yaw = yaw,
      pitch = pitch,
      min_distance = 1.0,
      max_distance = 20.0,
      min_pitch = -math.PI * 0.4,
      max_pitch = math.PI * 0.4,
      zoom_speed = 2.0,
      rotate_speed = 2.0,
    },
    last_mouse_pos = {0, 0},
    mouse_delta = {0, 0},
    scroll_delta = 0,
  }
}

// Free camera controller initialization
camera_controller_free_init :: proc(
  window: glfw.WindowHandle,
  move_speed := f32(5.0),
  rotation_speed := f32(2.0),
) -> CameraController {
  return CameraController{
    type = .FREE,
    window = window,
    data = FreeCameraData{
      move_speed = move_speed,
      rotation_speed = rotation_speed,
      boost_multiplier = 3.0,
      mouse_sensitivity = 0.002,
    },
    last_mouse_pos = {0, 0},
    mouse_delta = {0, 0},
    scroll_delta = 0,
  }
}

// Follow camera controller initialization
camera_controller_follow_init :: proc(
  window: glfw.WindowHandle,
  target: ^[3]f32,
  offset: [3]f32,
  follow_speed := f32(5.0),
) -> CameraController {
  return CameraController{
    type = .FOLLOW,
    window = window,
    data = FollowCameraData{
      target = target,
      offset = offset,
      follow_speed = follow_speed,
      look_at_target = true,
    },
    last_mouse_pos = {0, 0},
    mouse_delta = {0, 0},
    scroll_delta = 0,
  }
}

// Orbit controller update - self-contained with GLFW input gathering
camera_controller_orbit_update :: proc(
  controller: ^CameraController,
  camera: ^Camera,
  delta_time: f32,
) {
  orbit := &controller.data.(OrbitCameraData)
  
  // Gather input from GLFW
  current_mouse_pos: [2]f64
  current_mouse_pos.x, current_mouse_pos.y = glfw.GetCursorPos(controller.window)
  controller.mouse_delta = current_mouse_pos - controller.last_mouse_pos
  controller.last_mouse_pos = current_mouse_pos
  
  // Check mouse button state for rotation
  left_button_pressed := glfw.GetMouseButton(controller.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
  
  // Handle rotation when left mouse button is pressed
  if left_button_pressed {
    // Mouse movement should update yaw/pitch for orbiting
    orbit.yaw += f32(controller.mouse_delta.x) * orbit.rotate_speed * 0.01  // Positive for natural left/right movement
    orbit.pitch += f32(controller.mouse_delta.y) * orbit.rotate_speed * 0.01  // Positive for natural up/down movement
    orbit.pitch = clamp(orbit.pitch, orbit.min_pitch, orbit.max_pitch)
  }
  
  // Handle zoom with scroll wheel
  scroll := get_scroll_delta_for_window(controller.window)
  orbit.distance -= scroll * orbit.zoom_speed
  orbit.distance = clamp(orbit.distance, orbit.min_distance, orbit.max_distance)
  
  // Calculate camera position using spherical coordinates around target
  // Standard spherical coordinate system: yaw rotates around Y-axis, pitch tilts up/down
  x := orbit.distance * math.cos(orbit.pitch) * math.cos(orbit.yaw)
  y := orbit.distance * math.sin(orbit.pitch) 
  z := orbit.distance * math.cos(orbit.pitch) * math.sin(orbit.yaw)
  
  // Position camera at calculated offset from target, looking at target
  camera_position := orbit.target + [3]f32{x, y, z}
  camera_look_at(camera, camera_position, orbit.target)
}

// Free camera controller update - self-contained with GLFW input gathering
camera_controller_free_update :: proc(
  controller: ^CameraController,
  camera: ^Camera,
  delta_time: f32,
) {
  free := &controller.data.(FreeCameraData)
  
  // Gather keyboard input for movement
  move_vector := [3]f32{0, 0, 0}
  speed := free.move_speed
  
  // Check for boost with shift key
  if glfw.GetKey(controller.window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS {
    speed *= free.boost_multiplier
  }
  
  // WASD movement
  if glfw.GetKey(controller.window, glfw.KEY_W) == glfw.PRESS do move_vector += camera_forward(camera^)
  if glfw.GetKey(controller.window, glfw.KEY_S) == glfw.PRESS do move_vector -= camera_forward(camera^)
  if glfw.GetKey(controller.window, glfw.KEY_A) == glfw.PRESS do move_vector -= camera_right(camera^)
  if glfw.GetKey(controller.window, glfw.KEY_D) == glfw.PRESS do move_vector += camera_right(camera^)
  if glfw.GetKey(controller.window, glfw.KEY_Q) == glfw.PRESS do move_vector.y -= 1
  if glfw.GetKey(controller.window, glfw.KEY_E) == glfw.PRESS do move_vector.y += 1
  
  // Apply movement
  if linalg.length(move_vector) > 0 {
    move_vector = linalg.normalize(move_vector) * speed * delta_time
    camera_move(camera, move_vector)
  }
  
  // Gather mouse input for rotation
  current_mouse_pos: [2]f64
  current_mouse_pos.x, current_mouse_pos.y = glfw.GetCursorPos(controller.window)
  controller.mouse_delta = current_mouse_pos - controller.last_mouse_pos
  controller.last_mouse_pos = current_mouse_pos
  
  // Mouse look (only when right button held)
  right_button_pressed := glfw.GetMouseButton(controller.window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS
  if right_button_pressed {
    camera_rotate(camera, 
      f32(controller.mouse_delta.x) * free.mouse_sensitivity,
      f32(controller.mouse_delta.y) * free.mouse_sensitivity)
  }
}

// Follow camera controller update - self-contained
camera_controller_follow_update :: proc(
  controller: ^CameraController,
  camera: ^Camera,
  delta_time: f32,
) {
  follow := &controller.data.(FollowCameraData)
  
  if follow.target != nil {
    target_pos := follow.target^
    desired_pos := target_pos + follow.offset
    
    // Smooth interpolation
    current_pos := camera.position
    new_pos := linalg.lerp(current_pos, desired_pos, follow.follow_speed * delta_time)
    
    if follow.look_at_target {
      camera_look_at(camera, new_pos, target_pos)
    } else {
      camera_set_position(camera, new_pos)
    }
  }
}

// Configuration functions for orbit controller
camera_controller_orbit_set_target :: proc(controller: ^CameraController, target: [3]f32) {
  if orbit, ok := &controller.data.(OrbitCameraData); ok {
    orbit.target = target
  }
}

camera_controller_orbit_set_distance :: proc(controller: ^CameraController, distance: f32) {
  if orbit, ok := &controller.data.(OrbitCameraData); ok {
    orbit.distance = clamp(distance, orbit.min_distance, orbit.max_distance)
  }
}

camera_controller_orbit_set_yaw_pitch :: proc(controller: ^CameraController, yaw, pitch: f32) {
  if orbit, ok := &controller.data.(OrbitCameraData); ok {
    orbit.yaw = yaw
    orbit.pitch = clamp(pitch, orbit.min_pitch, orbit.max_pitch)
  }
}

// Configuration functions for free controller
camera_controller_free_set_speed :: proc(controller: ^CameraController, speed: f32) {
  if free, ok := &controller.data.(FreeCameraData); ok {
    free.move_speed = speed
  }
}

camera_controller_free_set_sensitivity :: proc(controller: ^CameraController, sensitivity: f32) {
  if free, ok := &controller.data.(FreeCameraData); ok {
    free.mouse_sensitivity = sensitivity
  }
}