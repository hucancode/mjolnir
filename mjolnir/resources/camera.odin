package resources

import "../gpu"

CameraData :: struct {
  view:             matrix[4, 4]f32,
  projection:       matrix[4, 4]f32,
  viewport_params:  [4]f32,
  position:         [4]f32,
  frustum_planes:   [6][4]f32,
}

// Get mutable reference to camera uniform in bindless buffer
get_camera_data :: proc(
  manager: ^Manager,
  camera_index: u32,
) -> ^CameraData {
  if camera_index >= MAX_ACTIVE_CAMERAS {
    return nil
  }
  return gpu.data_buffer_get(&manager.camera_buffer, camera_index)
}
