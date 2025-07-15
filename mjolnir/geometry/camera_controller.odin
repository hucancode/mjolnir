package geometry

import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"

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
  move_speed:        f32,
  rotation_speed:    f32,
  boost_multiplier:  f32,
  mouse_sensitivity: f32,
}

// Follow camera controller data (for future use)
FollowCameraData :: struct {
  target:         ^[3]f32, // Pointer to target position
  offset:         [3]f32,
  follow_speed:   f32,
  look_at_target: bool,
}

// Base controller structure with self-contained input
CameraController :: struct {
  type:           CameraControllerType,
  window:         glfw.WindowHandle, // Controller owns window for input
  data:           union {
    OrbitCameraData,
    FreeCameraData,
    FollowCameraData,
  },
  // Internal input state (private to controller)
  last_mouse_pos: [2]f64,
  mouse_delta:    [2]f64,
  scroll_delta:   f32,
  is_orbiting:    bool,
}

// Global scroll state for handling GLFW callbacks
@(private = "file")
g_scroll_deltas: map[glfw.WindowHandle]f32

// Helper to setup scroll callbacks (called once during controller setup)
setup_camera_controller_callbacks :: proc(window: glfw.WindowHandle) {
  glfw.SetScrollCallback(
    window,
    proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
      context = {} // GLFW callback context
      g_scroll_deltas[window] = f32(yoffset)
    },
  )
}

// Helper function for controllers to get and consume scroll delta
get_scroll_delta_for_window :: proc(window: glfw.WindowHandle) -> f32 {
  delta := g_scroll_deltas[window]
  g_scroll_deltas[window] = 0 // Reset after reading
  return delta
}

// Orbit controller initialization
camera_controller_orbit_init :: proc(
  window: glfw.WindowHandle,
  target: [3]f32,
  distance: f32,
  yaw :f32 = 0,
  pitch :f32 = 0,
) -> CameraController {
  // Get current mouse position to prevent jump on first input
  current_mouse_x, current_mouse_y := glfw.GetCursorPos(window)
  return {
    type = .ORBIT,
    window = window,
    data = OrbitCameraData {
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
    last_mouse_pos = {current_mouse_x, current_mouse_y},
    mouse_delta = {0, 0},
    scroll_delta = 0,
    is_orbiting = false,
  }
}

// Free camera controller initialization
camera_controller_free_init :: proc(
  window: glfw.WindowHandle,
  move_speed := f32(5.0),
  rotation_speed := f32(2.0),
) -> CameraController {
  // Get current mouse position to prevent jump on first input
  current_mouse_x, current_mouse_y := glfw.GetCursorPos(window)

  return {
    type = .FREE,
    window = window,
    data = FreeCameraData {
      move_speed = move_speed,
      rotation_speed = rotation_speed,
      boost_multiplier = 3.0,
      mouse_sensitivity = 0.002,
    },
    last_mouse_pos = {current_mouse_x, current_mouse_y},
    mouse_delta = {0, 0},
    scroll_delta = 0,
    is_orbiting = false,
  }
}

// Follow camera controller initialization
camera_controller_follow_init :: proc(
  window: glfw.WindowHandle,
  target: ^[3]f32,
  offset: [3]f32,
  follow_speed := f32(5.0),
) -> CameraController {
  // Get current mouse position to prevent jump on first input
  current_mouse_x, current_mouse_y := glfw.GetCursorPos(window)
  return {
    type = .FOLLOW,
    window = window,
    data = FollowCameraData {
      target = target,
      offset = offset,
      follow_speed = follow_speed,
      look_at_target = true,
    },
    last_mouse_pos = {current_mouse_x, current_mouse_y},
    mouse_delta = {0, 0},
    scroll_delta = 0,
    is_orbiting = false,
  }
}

// Orbit controller update - self-contained with GLFW input gathering
camera_controller_orbit_update :: proc(
  self: ^CameraController,
  camera: ^Camera,
  delta_time: f32,
) {
  orbit := &self.data.(OrbitCameraData)
  // Check mouse button state
  left_button_pressed :=
    glfw.GetMouseButton(self.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS

  // Handle orbiting state transitions
  if left_button_pressed && !self.is_orbiting {
    // Mouse down - start orbiting
    self.is_orbiting = true
    current_mouse_pos: [2]f64
    current_mouse_pos.x, current_mouse_pos.y = glfw.GetCursorPos(self.window)
    self.last_mouse_pos = current_mouse_pos
  } else if !left_button_pressed && self.is_orbiting {
    // Mouse up - stop orbiting
    self.is_orbiting = false
  }

  // Handle zoom with scroll wheel (always responsive)
  scroll := get_scroll_delta_for_window(self.window)
  if scroll != 0 {
    orbit.distance -= scroll * orbit.zoom_speed
    orbit.distance = clamp(
      orbit.distance,
      orbit.min_distance,
      orbit.max_distance,
    )
  }

  // Only update mouse delta and apply rotation when orbiting
  camera_needs_update := false
  if self.is_orbiting {
    current_mouse_pos: [2]f64
    current_mouse_pos.x, current_mouse_pos.y = glfw.GetCursorPos(self.window)
    self.mouse_delta = current_mouse_pos - self.last_mouse_pos
    self.last_mouse_pos = current_mouse_pos

    // Apply rotation only if there's actual mouse movement
    if self.mouse_delta.x != 0 || self.mouse_delta.y != 0 {
      orbit.yaw += f32(self.mouse_delta.x) * orbit.rotate_speed * 0.01
      orbit.pitch += f32(self.mouse_delta.y) * orbit.rotate_speed * 0.01
      orbit.pitch = linalg.clamp(orbit.pitch, orbit.min_pitch, orbit.max_pitch)
      camera_needs_update = true
    }
  }

  // Only update camera position/rotation when necessary
  if camera_needs_update || scroll != 0 {
    // Calculate camera position using spherical coordinates around target
    x := orbit.distance * math.cos(orbit.pitch) * math.cos(orbit.yaw)
    y := orbit.distance * math.sin(orbit.pitch)
    z := orbit.distance * math.cos(orbit.pitch) * math.sin(orbit.yaw)

    // Position camera at calculated offset from target, looking at target
    camera_position := orbit.target + [3]f32{x, y, z}
    camera_look_at(camera, camera_position, orbit.target)
  }
}

// Free camera controller update - self-contained with GLFW input gathering
camera_controller_free_update :: proc(
  self: ^CameraController,
  camera: ^Camera,
  delta_time: f32,
) {
  free := &self.data.(FreeCameraData)
  // Gather keyboard input for movement
  move_vector := [3]f32{0, 0, 0}
  speed := free.move_speed
  // Check for boost with shift key
  if glfw.GetKey(self.window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS {
    speed *= free.boost_multiplier
  }
  // WASD movement
  if glfw.GetKey(self.window, glfw.KEY_W) == glfw.PRESS do move_vector += camera_forward(camera^)
  if glfw.GetKey(self.window, glfw.KEY_S) == glfw.PRESS do move_vector -= camera_forward(camera^)
  if glfw.GetKey(self.window, glfw.KEY_A) == glfw.PRESS do move_vector -= camera_right(camera^)
  if glfw.GetKey(self.window, glfw.KEY_D) == glfw.PRESS do move_vector += camera_right(camera^)
  if glfw.GetKey(self.window, glfw.KEY_Q) == glfw.PRESS do move_vector.y -= 1
  if glfw.GetKey(self.window, glfw.KEY_E) == glfw.PRESS do move_vector.y += 1

  // Apply movement
  if linalg.length(move_vector) > 0 {
    move_vector = linalg.normalize(move_vector) * speed * delta_time
    camera_move(camera, move_vector)
  }
  // Check mouse button state
  right_button_pressed :=
    glfw.GetMouseButton(self.window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS

  // Handle mouse look state transitions
  if right_button_pressed && !self.is_orbiting {
    // Mouse down - start mouse look
    self.is_orbiting = true
    current_mouse_pos: [2]f64
    current_mouse_pos.x, current_mouse_pos.y = glfw.GetCursorPos(self.window)
    self.last_mouse_pos = current_mouse_pos
  } else if !right_button_pressed && self.is_orbiting {
    // Mouse up - stop mouse look
    self.is_orbiting = false
  }

  // Only update mouse delta and apply rotation when in mouse look mode
  if self.is_orbiting {
    current_mouse_pos: [2]f64
    current_mouse_pos.x, current_mouse_pos.y = glfw.GetCursorPos(self.window)
    self.mouse_delta = current_mouse_pos - self.last_mouse_pos
    self.last_mouse_pos = current_mouse_pos

    // Apply rotation
    camera_rotate(
      camera,
      f32(self.mouse_delta.x) * free.mouse_sensitivity,
      f32(self.mouse_delta.y) * free.mouse_sensitivity,
    )
  }
}

// Follow camera controller update - self-contained
camera_controller_follow_update :: proc(
  self: ^CameraController,
  camera: ^Camera,
  delta_time: f32,
) {
  follow := &self.data.(FollowCameraData)

  if follow.target != nil {
    target_pos := follow.target^
    desired_pos := target_pos + follow.offset

    // Smooth interpolation
    current_pos := camera.position
    new_pos := linalg.lerp(
      current_pos,
      desired_pos,
      follow.follow_speed * delta_time,
    )

    if follow.look_at_target {
      camera_look_at(camera, new_pos, target_pos)
    } else {
      camera_set_position(camera, new_pos)
    }
  }
}

// Sync current camera state to orbit controller to prevent jumps
camera_controller_orbit_sync :: proc(
  controller: ^CameraController,
  camera: ^Camera,
) {
  if orbit, ok := &controller.data.(OrbitCameraData); ok {
    // Calculate spherical coordinates from current camera position relative to target
    offset := camera.position - orbit.target
    orbit.distance = linalg.length(offset)

    if orbit.distance > 0.001 {
      // Calculate yaw (rotation around Y axis)
      orbit.yaw = math.atan2(offset.z, offset.x)

      // Calculate pitch (up/down angle)
      horizontal_distance := math.sqrt(
        offset.x * offset.x + offset.z * offset.z,
      )
      orbit.pitch = math.atan2(offset.y, horizontal_distance)

      // Clamp values to valid ranges
      orbit.pitch = clamp(orbit.pitch, orbit.min_pitch, orbit.max_pitch)
      orbit.distance = clamp(
        orbit.distance,
        orbit.min_distance,
        orbit.max_distance,
      )

      // Immediately apply the synced state to the camera to ensure first frame is correct
      x := orbit.distance * math.cos(orbit.pitch) * math.cos(orbit.yaw)
      y := orbit.distance * math.sin(orbit.pitch)
      z := orbit.distance * math.cos(orbit.pitch) * math.sin(orbit.yaw)
      camera_position := orbit.target + [3]f32{x, y, z}
      camera_look_at(camera, camera_position, orbit.target)
    }
  }
}

// Sync current camera state to free controller (free camera stores position/rotation directly in Camera)
camera_controller_free_sync :: proc(
  controller: ^CameraController,
  camera: ^Camera,
) {
  // Free camera controller doesn't need explicit syncing since it directly modifies
  // the camera's position and rotation. The camera object already contains the current state.
  // This procedure exists for API consistency and potential future use.
}

// Generic sync procedure that works with any controller type
camera_controller_sync :: proc(
  controller: ^CameraController,
  camera: ^Camera,
) {
  switch controller.type {
  case .ORBIT:
    camera_controller_orbit_sync(controller, camera)
  case .FREE:
    camera_controller_free_sync(controller, camera)
  case .FOLLOW:
  // Follow camera doesn't need syncing as it automatically follows its target
  case .CINEMATIC:
  // Cinematic camera doesn't need syncing as it follows predefined paths
  }
}

// Configuration functions for orbit controller
camera_controller_orbit_set_target :: proc(
  controller: ^CameraController,
  target: [3]f32,
) {
  if orbit, ok := &controller.data.(OrbitCameraData); ok {
    orbit.target = target
  }
}

camera_controller_orbit_set_distance :: proc(
  controller: ^CameraController,
  distance: f32,
) {
  if orbit, ok := &controller.data.(OrbitCameraData); ok {
    orbit.distance = linalg.clamp(
      distance,
      orbit.min_distance,
      orbit.max_distance,
    )
  }
}

camera_controller_orbit_set_yaw_pitch :: proc(
  controller: ^CameraController,
  yaw, pitch: f32,
) {
  if orbit, ok := &controller.data.(OrbitCameraData); ok {
    orbit.yaw = yaw
    orbit.pitch = linalg.clamp(pitch, orbit.min_pitch, orbit.max_pitch)
  }
}

// Configuration functions for free controller
camera_controller_free_set_speed :: proc(
  controller: ^CameraController,
  speed: f32,
) {
  if free, ok := &controller.data.(FreeCameraData); ok {
    free.move_speed = speed
  }
}

camera_controller_free_set_sensitivity :: proc(
  controller: ^CameraController,
  sensitivity: f32,
) {
  if free, ok := &controller.data.(FreeCameraData); ok {
    free.mouse_sensitivity = sensitivity
  }
}
