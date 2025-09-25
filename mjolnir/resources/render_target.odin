package resources

import "core:log"
import "core:math"
import "../geometry"
import "../gpu"
import vk "vendor:vulkan"

RenderTargetFeature :: enum {
  FINAL_IMAGE         = 0,
  POSITION_TEXTURE    = 1,
  NORMAL_TEXTURE      = 2,
  ALBEDO_TEXTURE      = 3,
  METALLIC_ROUGHNESS  = 4,
  EMISSIVE_TEXTURE    = 5,
  DEPTH_TEXTURE       = 6,
}

RenderTargetFeatureSet :: bit_set[RenderTargetFeature;u32]

RENDER_TARGET_FEATURE_COUNT: u32 : len(RenderTargetFeature)

RenderTarget :: struct {
  camera:                          Handle,
  extent:                          vk.Extent2D,
  features:                        RenderTargetFeatureSet,
  // Texture handles per frame in flight
  final_images:                    [MAX_FRAMES_IN_FLIGHT]Handle,
  position_textures:               [MAX_FRAMES_IN_FLIGHT]Handle,
  normal_textures:                 [MAX_FRAMES_IN_FLIGHT]Handle,
  albedo_textures:                 [MAX_FRAMES_IN_FLIGHT]Handle,
  metallic_roughness_textures:     [MAX_FRAMES_IN_FLIGHT]Handle,
  emissive_textures:               [MAX_FRAMES_IN_FLIGHT]Handle,
  depth_textures:                  [MAX_FRAMES_IN_FLIGHT]Handle,
}

render_target_init :: proc(
  target: ^RenderTarget,
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
  features: RenderTargetFeatureSet = {.FINAL_IMAGE, .POSITION_TEXTURE, .NORMAL_TEXTURE, .ALBEDO_TEXTURE, .METALLIC_ROUGHNESS, .EMISSIVE_TEXTURE, .DEPTH_TEXTURE},
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = math.PI * 0.5,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> vk.Result {
  camera_ptr: ^geometry.Camera
  target.camera, camera_ptr = alloc(&manager.cameras)
  camera_ptr^ = geometry.make_camera_perspective(
    fov,
    f32(width) / f32(height),
    near_plane,
    far_plane,
  )
  geometry.camera_look_at(camera_ptr, camera_position, camera_target)

  target.extent = {width, height}
  target.features = features

  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    if .FINAL_IMAGE in features {
      target.final_images[frame], _, _ = create_texture(
        gpu_context,
        manager,
        width,
        height,
        color_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }

    if .POSITION_TEXTURE in features {
      target.position_textures[frame], _, _ = create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R32G32B32A32_SFLOAT,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }

    if .NORMAL_TEXTURE in features {
      target.normal_textures[frame], _, _ = create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }

    if .ALBEDO_TEXTURE in features {
      target.albedo_textures[frame], _, _ = create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }

    if .METALLIC_ROUGHNESS in features {
      target.metallic_roughness_textures[frame], _, _ = create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }

    if .EMISSIVE_TEXTURE in features {
      target.emissive_textures[frame], _, _ = create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }

    if .DEPTH_TEXTURE in features {
      target.depth_textures[frame], _, _ = create_texture(
        gpu_context,
        manager,
        width,
        height,
        depth_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }
  }

  return .SUCCESS
}

render_target_detroy :: proc(
  target: ^RenderTarget,
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  free(&manager.cameras, target.camera)
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    if .FINAL_IMAGE in target.features {
      if item, freed := free(
        &manager.image_2d_buffers,
        target.final_images[frame],
      ); freed {
        gpu.image_buffer_detroy(gpu_context, item)
      }
    }
    if .POSITION_TEXTURE in target.features {
      if item, freed := free(
        &manager.image_2d_buffers,
        target.position_textures[frame],
      ); freed {
        gpu.image_buffer_detroy(gpu_context, item)
      }
    }
    if .NORMAL_TEXTURE in target.features {
      if item, freed := free(
        &manager.image_2d_buffers,
        target.normal_textures[frame],
      ); freed {
        gpu.image_buffer_detroy(gpu_context, item)
      }
    }
    if .ALBEDO_TEXTURE in target.features {
      if item, freed := free(
        &manager.image_2d_buffers,
        target.albedo_textures[frame],
      ); freed {
        gpu.image_buffer_detroy(gpu_context, item)
      }
    }
    if .METALLIC_ROUGHNESS in target.features {
      if item, freed := free(
        &manager.image_2d_buffers,
        target.metallic_roughness_textures[frame],
      ); freed {
        gpu.image_buffer_detroy(gpu_context, item)
      }
    }
    if .EMISSIVE_TEXTURE in target.features {
      if item, freed := free(
        &manager.image_2d_buffers,
        target.emissive_textures[frame],
      ); freed {
        gpu.image_buffer_detroy(gpu_context, item)
      }
    }
    if .DEPTH_TEXTURE in target.features {
      if item, freed := free(
        &manager.image_2d_buffers,
        target.depth_textures[frame],
      ); freed {
        gpu.image_buffer_detroy(gpu_context, item)
      }
    }
  }
}

// Update camera uniform for the render target using bindless camera buffer
render_target_update_camera_data :: proc(
  manager: ^Manager,
  target: ^RenderTarget,
) {
  camera_ptr, ok := get_camera(manager, target.camera)
  uniform := get_camera_data(manager, target.camera.index)
  if !ok || camera_ptr == nil || uniform == nil {
    log.errorf("Camera %v or uniform missing", target.camera)
    return
  }
  camera_data_update(
    uniform,
    camera_ptr,
    target.extent.width,
    target.extent.height,
  )
}

// Get texture handles for current frame
render_target_get_current_textures :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> (
  final_image: Handle,
  position_texture: Handle,
  normal_texture: Handle,
  albedo_texture: Handle,
  metallic_roughness_texture: Handle,
  emissive_texture: Handle,
  depth_texture: Handle,
) {
  frame := frame_index
  return target.final_images[frame],
    target.position_textures[frame],
    target.normal_textures[frame],
    target.albedo_textures[frame],
    target.metallic_roughness_textures[frame],
    target.emissive_textures[frame],
    target.depth_textures[frame]
}

// Get specific texture for current frame
get_final_image :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.final_images[frame_index]
}

get_position_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.position_textures[frame_index]
}

get_normal_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.normal_textures[frame_index]
}

get_albedo_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.albedo_textures[frame_index]
}

get_metallic_roughness_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.metallic_roughness_textures[frame_index]
}

get_emissive_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.emissive_textures[frame_index]
}

get_depth_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.depth_textures[frame_index]
}
