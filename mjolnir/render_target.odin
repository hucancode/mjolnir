package mjolnir

import "core:log"
import "core:math"
import "geometry"
import "resource"
import vk "vendor:vulkan"

RenderTarget :: struct {
  camera:                          Handle,
  extent:                          vk.Extent2D,
  // Texture handles per frame in flight
  final_images:                    [MAX_FRAMES_IN_FLIGHT]Handle,
  position_textures:               [MAX_FRAMES_IN_FLIGHT]Handle,
  normal_textures:                 [MAX_FRAMES_IN_FLIGHT]Handle,
  albedo_textures:                 [MAX_FRAMES_IN_FLIGHT]Handle,
  metallic_roughness_textures:     [MAX_FRAMES_IN_FLIGHT]Handle,
  emissive_textures:               [MAX_FRAMES_IN_FLIGHT]Handle,
  depth_textures:                  [MAX_FRAMES_IN_FLIGHT]Handle,
  // Ownership flags for textures (true = owned by this RenderTarget)
  owns_final_image:                bool,
  owns_position_texture:           bool,
  owns_normal_texture:             bool,
  owns_albedo_texture:             bool,
  owns_metallic_roughness_texture: bool,
  owns_emissive_texture:           bool,
  owns_depth_texture:              bool,
}

render_target_init :: proc(
  gpu_context: ^GPUContext,
  target: ^RenderTarget,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = math.PI * 0.5,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> vk.Result {
  camera_ptr: ^geometry.Camera
  target.camera, camera_ptr = resource.alloc(&g_cameras)
  camera_ptr^ = geometry.make_camera_perspective(
    fov,
    f32(width) / f32(height),
    near_plane,
    far_plane,
  )
  geometry.camera_look_at(camera_ptr, camera_position, camera_target)

  target.extent = {width, height}
  // Create textures for all frames in flight
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    // Create all texture handles and mark as owned
    target.final_images[frame], _ = create_empty_texture_2d(
      gpu_context,
      width,
      height,
      color_format,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return

    target.position_textures[frame], _ = create_empty_texture_2d(
      gpu_context,
      width,
      height,
      .R32G32B32A32_SFLOAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return

    target.normal_textures[frame], _ = create_empty_texture_2d(
      gpu_context,
      width,
      height,
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return

    target.albedo_textures[frame], _ = create_empty_texture_2d(
      gpu_context,
      width,
      height,
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return

    target.metallic_roughness_textures[frame], _ = create_empty_texture_2d(
      gpu_context,
      width,
      height,
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return

    target.emissive_textures[frame], _ = create_empty_texture_2d(
      gpu_context,
      width,
      height,
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return

    target.depth_textures[frame], _ = create_empty_texture_2d(
      gpu_context,
      width,
      height,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
  }

  target.owns_final_image = true
  target.owns_position_texture = true
  target.owns_normal_texture = true
  target.owns_albedo_texture = true
  target.owns_metallic_roughness_texture = true
  target.owns_emissive_texture = true
  target.owns_depth_texture = true

  return .SUCCESS
}

// Clean up RenderTarget resources (camera and owned textures)
render_target_deinit :: proc(gpu_context: ^GPUContext, target: ^RenderTarget) {
  // Always release camera since we always own it
  resource.free(&g_cameras, target.camera)
  // Release only owned texture handles for all frames
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    if target.owns_final_image {
      if item, freed := resource.free(&g_image_2d_buffers, target.final_images[frame]); freed {
        image_buffer_deinit(gpu_context, item)
      }
    }
    if target.owns_position_texture {
      if item, freed := resource.free(&g_image_2d_buffers, target.position_textures[frame]); freed {
        image_buffer_deinit(gpu_context, item)
      }
    }
    if target.owns_normal_texture {
      if item, freed := resource.free(&g_image_2d_buffers, target.normal_textures[frame]); freed {
        image_buffer_deinit(gpu_context, item)
      }
    }
    if target.owns_albedo_texture {
      if item, freed := resource.free(&g_image_2d_buffers, target.albedo_textures[frame]); freed {
        image_buffer_deinit(gpu_context, item)
      }
    }
    if target.owns_metallic_roughness_texture {
      if item, freed := resource.free(&g_image_2d_buffers, target.metallic_roughness_textures[frame]); freed {
        image_buffer_deinit(gpu_context, item)
      }
    }
    if target.owns_emissive_texture {
      if item, freed := resource.free(&g_image_2d_buffers, target.emissive_textures[frame]); freed {
        image_buffer_deinit(gpu_context, item)
      }
    }
    if target.owns_depth_texture {
      if item, freed := resource.free(&g_image_2d_buffers, target.depth_textures[frame]); freed {
        image_buffer_deinit(gpu_context, item)
      }
    }
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
  camera_uniform_update(
    uniform,
    camera,
    target.extent.width,
    target.extent.height,
  )
}

// Get texture handles for current frame
render_target_get_current_textures :: proc(
  target: ^RenderTarget,
) -> (
  final_image: Handle,
  position_texture: Handle,
  normal_texture: Handle,
  albedo_texture: Handle,
  metallic_roughness_texture: Handle,
  emissive_texture: Handle,
  depth_texture: Handle,
) {
  frame := g_frame_index
  return target.final_images[frame],
    target.position_textures[frame],
    target.normal_textures[frame],
    target.albedo_textures[frame],
    target.metallic_roughness_textures[frame],
    target.emissive_textures[frame],
    target.depth_textures[frame]
}

// Get camera for this render target
render_target_get_camera :: proc(target: ^RenderTarget) -> ^geometry.Camera {
  return resource.get(g_cameras, target.camera)
}

// Get specific texture for current frame
render_target_final_image :: proc(target: ^RenderTarget) -> Handle {
  return target.final_images[g_frame_index]
}

render_target_position_texture :: proc(target: ^RenderTarget) -> Handle {
  return target.position_textures[g_frame_index]
}

render_target_normal_texture :: proc(target: ^RenderTarget) -> Handle {
  return target.normal_textures[g_frame_index]
}

render_target_albedo_texture :: proc(target: ^RenderTarget) -> Handle {
  return target.albedo_textures[g_frame_index]
}

render_target_metallic_roughness_texture :: proc(
  target: ^RenderTarget,
) -> Handle {
  return target.metallic_roughness_textures[g_frame_index]
}

render_target_emissive_texture :: proc(target: ^RenderTarget) -> Handle {
  return target.emissive_textures[g_frame_index]
}

render_target_depth_texture :: proc(target: ^RenderTarget) -> Handle {
  return target.depth_textures[g_frame_index]
}
