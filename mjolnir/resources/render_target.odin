package resources

import "../geometry"
import "../gpu"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

RenderTargetFeature :: enum {
  FINAL_IMAGE        = 0,
  POSITION_TEXTURE   = 1,
  NORMAL_TEXTURE     = 2,
  ALBEDO_TEXTURE     = 3,
  METALLIC_ROUGHNESS = 4,
  EMISSIVE_TEXTURE   = 5,
  DEPTH_TEXTURE      = 6,
}

RenderTargetFeatureSet :: bit_set[RenderTargetFeature;u32]

RENDER_TARGET_FEATURE_COUNT: u32 : len(RenderTargetFeature)

RenderTarget :: struct {
  camera:                      Handle,
  extent:                      vk.Extent2D,
  features:                    RenderTargetFeatureSet,
  // Texture handles per frame in flight
  final_images:                [MAX_FRAMES_IN_FLIGHT]Handle,
  position_textures:           [MAX_FRAMES_IN_FLIGHT]Handle,
  normal_textures:             [MAX_FRAMES_IN_FLIGHT]Handle,
  albedo_textures:             [MAX_FRAMES_IN_FLIGHT]Handle,
  metallic_roughness_textures: [MAX_FRAMES_IN_FLIGHT]Handle,
  emissive_textures:           [MAX_FRAMES_IN_FLIGHT]Handle,
  depth_textures:              [MAX_FRAMES_IN_FLIGHT]Handle,
}

render_target_init :: proc(
  target: ^RenderTarget,
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
  features: RenderTargetFeatureSet = {
    .FINAL_IMAGE,
    .POSITION_TEXTURE,
    .NORMAL_TEXTURE,
    .ALBEDO_TEXTURE,
    .METALLIC_ROUGHNESS,
    .EMISSIVE_TEXTURE,
    .DEPTH_TEXTURE,
  },
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

render_target_destroy :: proc(
  target: ^RenderTarget,
  device: vk.Device,
  manager: ^Manager,
) {
  free(&manager.cameras, target.camera)
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    if item, freed := free(
      &manager.image_2d_buffers,
      target.final_images[frame],
    ); freed {
      gpu.image_buffer_destroy(device, item)
    }
    if item, freed := free(
      &manager.image_2d_buffers,
      target.position_textures[frame],
    ); freed {
      gpu.image_buffer_destroy(device, item)
    }
    if item, freed := free(
      &manager.image_2d_buffers,
      target.normal_textures[frame],
    ); freed {
      gpu.image_buffer_destroy(device, item)
    }
    if item, freed := free(
      &manager.image_2d_buffers,
      target.albedo_textures[frame],
    ); freed {
      gpu.image_buffer_destroy(device, item)
    }
    if item, freed := free(
      &manager.image_2d_buffers,
      target.metallic_roughness_textures[frame],
    ); freed {
      gpu.image_buffer_destroy(device, item)
    }
    if item, freed := free(
      &manager.image_2d_buffers,
      target.emissive_textures[frame],
    ); freed {
      gpu.image_buffer_destroy(device, item)
    }
    if item, freed := free(
      &manager.image_2d_buffers,
      target.depth_textures[frame],
    ); freed {
      gpu.image_buffer_destroy(device, item)
    }
  }
}

render_target_upload_camera_data :: proc(
  manager: ^Manager,
  target: ^RenderTarget,
) {
  dst := gpu.data_buffer_get(&manager.camera_buffer, target.camera.index)
  camera, ok := get_camera(manager, target.camera)
  if dst == nil || !ok {
    log.errorf("Camera %v or uniform missing", target.camera)
    return
  }
  dst.view, dst.projection = geometry.camera_calculate_matrices(camera^)
  near, far := geometry.camera_get_near_far(camera^)
  dst.viewport_params = [4]f32 {
    f32(target.extent.width),
    f32(target.extent.height),
    near,
    far,
  }
  dst.position = [4]f32 {
    camera.position[0],
    camera.position[1],
    camera.position[2],
    1.0,
  }
  frustum := geometry.make_frustum(dst.projection * dst.view)
  dst.frustum_planes = frustum.planes
}

get_final_image :: proc(target: ^RenderTarget, frame_index: u32) -> Handle {
  return target.final_images[frame_index]
}

get_position_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> Handle {
  return target.position_textures[frame_index]
}

get_normal_texture :: proc(target: ^RenderTarget, frame_index: u32) -> Handle {
  return target.normal_textures[frame_index]
}

get_albedo_texture :: proc(target: ^RenderTarget, frame_index: u32) -> Handle {
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

get_depth_texture :: proc(target: ^RenderTarget, frame_index: u32) -> Handle {
  return target.depth_textures[frame_index]
}
