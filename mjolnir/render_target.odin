package mjolnir

import "core:log"
import "resource"
import vk "vendor:vulkan"
import "geometry"

// RenderTarget describes the output textures and camera for a render pass.
RenderTarget :: struct {
  // Camera management
  camera:                          Handle,
  extent:                          vk.Extent2D,
  // Texture handles (may or may not be owned by this render target)
  final_image:                     Handle,
  position_texture:                Handle,
  normal_texture:                  Handle,
  albedo_texture:                  Handle,
  metallic_roughness_texture:      Handle,
  emissive_texture:                Handle,
  depth_texture:                   Handle,
  // Ownership flags for textures (true = owned by this RenderTarget)
  owns_final_image:                bool,
  owns_position_texture:           bool,
  owns_normal_texture:             bool,
  owns_albedo_texture:             bool,
  owns_metallic_roughness_texture: bool,
  owns_emissive_texture:           bool,
  owns_depth_texture:              bool,
}

// Initialize RenderTarget with camera and create all textures
render_target_init :: proc(
  target: ^RenderTarget,
  camera: resource.Handle,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  target.camera = camera
  target.extent = {width, height}

  // Create all texture handles and mark as owned
  target.final_image, _ = create_empty_texture_2d(
    width,
    height,
    color_format,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  target.owns_final_image = true

  target.position_texture, _ = create_empty_texture_2d(
    width,
    height,
    .R32G32B32A32_SFLOAT,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  target.owns_position_texture = true

  target.normal_texture, _ = create_empty_texture_2d(
    width,
    height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  target.owns_normal_texture = true

  target.albedo_texture, _ = create_empty_texture_2d(
    width,
    height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  target.owns_albedo_texture = true

  target.metallic_roughness_texture, _ = create_empty_texture_2d(
    width,
    height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  target.owns_metallic_roughness_texture = true

  target.emissive_texture, _ = create_empty_texture_2d(
    width,
    height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  target.owns_emissive_texture = true

  target.depth_texture, _ = create_empty_texture_2d(
    width,
    height,
    depth_format,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  ) or_return
  target.owns_depth_texture = true

  return .SUCCESS
}

// Clean up RenderTarget resources (only owned textures)
render_target_deinit :: proc(target: ^RenderTarget) {

  // Release only owned texture handles
  if target.owns_final_image {
    resource.free(&g_image_2d_buffers, target.final_image, image_buffer_deinit)
  }
  if target.owns_position_texture {
    resource.free(
      &g_image_2d_buffers,
      target.position_texture,
      image_buffer_deinit,
    )
  }
  if target.owns_normal_texture {
    resource.free(
      &g_image_2d_buffers,
      target.normal_texture,
      image_buffer_deinit,
    )
  }
  if target.owns_albedo_texture {
    resource.free(
      &g_image_2d_buffers,
      target.albedo_texture,
      image_buffer_deinit,
    )
  }
  if target.owns_metallic_roughness_texture {
    resource.free(
      &g_image_2d_buffers,
      target.metallic_roughness_texture,
      image_buffer_deinit,
    )
  }
  if target.owns_emissive_texture {
    resource.free(
      &g_image_2d_buffers,
      target.emissive_texture,
      image_buffer_deinit,
    )
  }
  if target.owns_depth_texture {
    resource.free(
      &g_image_2d_buffers,
      target.depth_texture,
      image_buffer_deinit,
    )
  }
}

// Update camera uniform for the render target using bindless camera buffer
render_target_update_camera_uniform :: proc(target: ^RenderTarget) {
  camera := resource.get(g_cameras, target.camera)
  uniform := get_camera_uniform(target.camera.index)
  if camera == nil || uniform == nil {
    log.errorf("Camera %v or uniform %v not found", target.camera, uniform)
    return
  }
  camera_uniform_update(uniform, camera, target.extent.width, target.extent.height)
}

// Helper function to find camera slot in active render targets
find_camera_slot :: proc(
  camera_handle: resource.Handle,
  active_render_targets: []RenderTarget,
) -> (
  slot: u32,
  found: bool,
) {
  for target, i in active_render_targets {
    if target.camera.index == camera_handle.index {
      return u32(i), true
    }
  }
  return 0, false
}
