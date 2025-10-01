package targets

import "../../geometry"
import "../../gpu"
import "../../resources"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  POSITION           = 1,
  NORMAL             = 2,
  ALBEDO             = 3,
  METALLIC_ROUGHNESS = 4,
  EMISSIVE           = 5,
  DEPTH              = 6,
}

ATTACHMENT_COUNT :: len(AttachmentType)

PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  NAVIGATION   = 5,
  POST_PROCESS = 6,
}

PassTypeSet :: bit_set[PassType;u32]

RenderTarget :: struct {
  camera:          resources.Handle,
  extent:          vk.Extent2D,
  attachments:     [AttachmentType][resources.MAX_FRAMES_IN_FLIGHT]resources.Handle,
  enabled_passes:  PassTypeSet,
  command_buffers: [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

render_target_init :: proc(
  self: ^RenderTarget,
  gpu_context: ^gpu.GPUContext,
  manager: ^resources.Manager,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
  enabled_passes: PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .NAVIGATION,
    .POST_PROCESS,
  },
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = math.PI * 0.5,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> vk.Result {
  // Create camera
  camera_ptr: ^geometry.Camera
  self.camera, camera_ptr = resources.alloc(&manager.cameras)
  camera_ptr^ = geometry.make_camera_perspective(
    fov,
    f32(width) / f32(height),
    near_plane,
    far_plane,
  )
  geometry.camera_look_at(camera_ptr, camera_position, camera_target)

  self.extent = {width, height}
  self.enabled_passes = enabled_passes

  // Create attachments based on enabled passes
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes
  needs_depth := needs_gbuffer || .SHADOW in enabled_passes

  for frame in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    if needs_final {
      self.attachments[.FINAL_IMAGE][frame], _, _ = resources.create_texture(
        gpu_context,
        manager,
        width,
        height,
        color_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }
    if needs_gbuffer {
      self.attachments[.POSITION][frame], _, _ = resources.create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R32G32B32A32_SFLOAT,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      self.attachments[.NORMAL][frame], _, _ = resources.create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      self.attachments[.ALBEDO][frame], _, _ = resources.create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      self.attachments[.METALLIC_ROUGHNESS][frame], _, _ =
        resources.create_texture(
          gpu_context,
          manager,
          width,
          height,
          vk.Format.R8G8B8A8_UNORM,
          vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
        )
      self.attachments[.EMISSIVE][frame], _, _ = resources.create_texture(
        gpu_context,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }
    if needs_depth {
      self.attachments[.DEPTH][frame], _, _ = resources.create_texture(
        gpu_context,
        manager,
        width,
        height,
        depth_format,
        vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      )
    }
  }

  // Allocate command buffers
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool        = gpu_context.command_pool,
    level              = .SECONDARY,
    commandBufferCount = resources.MAX_FRAMES_IN_FLIGHT,
  }
  vk.AllocateCommandBuffers(
    gpu_context.device,
    &alloc_info,
    raw_data(self.command_buffers[:]),
  ) or_return

  return .SUCCESS
}

render_target_destroy :: proc(
  self: ^RenderTarget,
  device: vk.Device,
  command_pool: vk.CommandPool,
  manager: ^resources.Manager,
) {
  // Free camera
  resources.free(&manager.cameras, self.camera)

  // Free all attachments
  for attachment_type in AttachmentType {
    for frame in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
      handle := self.attachments[attachment_type][frame]
      if handle.generation > 0 {
        if item, freed := resources.free(&manager.image_2d_buffers, handle);
           freed {
          gpu.image_buffer_destroy(device, item)
        }
      }
    }
  }

  // Free command buffers
  vk.FreeCommandBuffers(
    device,
    command_pool,
    resources.MAX_FRAMES_IN_FLIGHT,
    raw_data(self.command_buffers[:]),
  )
  self.command_buffers = {}
}

render_target_upload_camera_data :: proc(
  manager: ^resources.Manager,
  target: ^RenderTarget,
) {
  dst := gpu.data_buffer_get(&manager.camera_buffer, target.camera.index)
  camera, ok := resources.get_camera(manager, target.camera)
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

get_attachment :: proc(
  target: ^RenderTarget,
  attachment_type: AttachmentType,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[attachment_type][frame_index]
}

get_final_image :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[.FINAL_IMAGE][frame_index]
}

get_position_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[.POSITION][frame_index]
}

get_normal_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[.NORMAL][frame_index]
}

get_albedo_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[.ALBEDO][frame_index]
}

get_metallic_roughness_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[.METALLIC_ROUGHNESS][frame_index]
}

get_emissive_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[.EMISSIVE][frame_index]
}

get_depth_texture :: proc(
  target: ^RenderTarget,
  frame_index: u32,
) -> resources.Handle {
  return target.attachments[.DEPTH][frame_index]
}

render_target_resize :: proc(
  self: ^RenderTarget,
  gpu_context: ^gpu.GPUContext,
  manager: ^resources.Manager,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  if self.extent.width == width && self.extent.height == height do return .SUCCESS

  self.extent = {width, height}

  camera, camera_ok := resources.get_camera(manager, self.camera)
  if !camera_ok do return .ERROR_UNKNOWN

  if perspective, ok := &camera.projection.(geometry.PerspectiveProjection);
     ok {
    perspective.aspect_ratio = f32(width) / f32(height)
  }

  return .SUCCESS
}

create_render_target :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^resources.Manager,
  width, height: u32,
  color_format: vk.Format = vk.Format.R8G8B8A8_UNORM,
  depth_format: vk.Format = vk.Format.D32_SFLOAT,
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
  enabled_passes: PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .NAVIGATION,
    .POST_PROCESS,
  },
) -> (
  result: RenderTarget,
  ok: bool,
) {
  target: RenderTarget
  init_result := render_target_init(
    &target,
    gpu_context,
    manager,
    width,
    height,
    color_format,
    depth_format,
    enabled_passes = enabled_passes,
    camera_position = camera_position,
    camera_target = camera_target,
    fov = fov,
    near_plane = near_plane,
    far_plane = far_plane,
  )
  if init_result != .SUCCESS {
    return {}, false
  }
  return target, true
}
