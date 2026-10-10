package render

import "bindless"
import cont "../containers"
import geom "../geometry"
import "gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import "occlusion_culling"
import vk "vendor:vulkan"

// ---------- pose + projection (CPU) ----------

camera_view_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  return linalg.matrix4_look_at(
    camera.position,
    camera.position + camera_forward(camera),
    camera_up(camera),
  )
}

camera_projection_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return geom.make_perspective_matrix(
      proj.fov,
      proj.aspect_ratio,
      proj.near,
      proj.far,
    )
  case OrthographicProjection:
    hw := proj.width / 2
    hh := proj.height / 2
    return geom.make_ortho_matrix(-hw, hw, -hh, hh, proj.near, proj.far)
  }
  return linalg.MATRIX4F32_IDENTITY
}

camera_forward :: proc(self: ^Camera) -> [3]f32 {
  return -geom.qz(self.rotation)
}

camera_right :: proc(self: ^Camera) -> [3]f32 {
  return geom.qx(self.rotation)
}

camera_up :: proc(self: ^Camera) -> [3]f32 {
  return geom.qy(self.rotation)
}

camera_get_near_far :: proc(self: ^Camera) -> (near: f32, far: f32) {
  switch proj in self.projection {
  case PerspectiveProjection:
    return proj.near, proj.far
  case OrthographicProjection:
    return proj.near, proj.far
  }
  return 0.1, 50.0
}

// `up` is the desired world-up reference. Pass {0,0,0} (default) to auto-pick
// a safe up that avoids gimbal lock — but that auto-pick switches axes
// discretely near the poles and snaps the view. Callers that know a smooth,
// view-orthogonal up (e.g. orbit derives one from yaw/pitch) should pass it.
camera_look_at :: proc(self: ^Camera, from, to: [3]f32, up: [3]f32 = {0, 0, 0}) {
  self.position = from
  forward := linalg.normalize(to - from)
  safe_up := up
  if linalg.length2(safe_up) < 1e-6 {
    safe_up = linalg.VECTOR3F32_Y_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_Z_AXIS
      if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
        safe_up = linalg.VECTOR3F32_X_AXIS
      }
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := matrix[3, 3]f32{
    right.x, recalc_up.x, -forward.x,
    right.y, recalc_up.y, -forward.y,
    right.z, recalc_up.z, -forward.z,
  }
  self.rotation = linalg.to_quaternion(rotation_matrix)
}

// Place a camera with a world matrix (e.g. a node's world transform when the
// camera follows a logical entity). The camera looks down the matrix's -Z.
camera_set_transform :: proc(self: ^Camera, world_matrix: matrix[4, 4]f32) {
  self.position = world_matrix[3].xyz
  self.rotation = linalg.quaternion_from_matrix4_f32(world_matrix)
}

camera_set_perspective :: proc(
  self: ^Camera,
  fov: f32 = math.PI / 3,
  near: f32 = 0.1,
  far: f32 = 1000.0,
) {
  self.projection = PerspectiveProjection {
    fov          = fov,
    aspect_ratio = f32(self.extent[0]) / f32(max(self.extent[1], 1)),
    near         = near,
    far          = far,
  }
}

camera_set_orthographic :: proc(
  self: ^Camera,
  width, height: f32,
  near: f32 = 0.1,
  far: f32 = 100.0,
) {
  self.projection = OrthographicProjection {
    width  = width,
    height = height,
    near   = near,
    far    = far,
  }
}

// World-space ray through a viewport pixel (framebuffer pixels, origin top-left).
camera_viewport_to_world_ray :: proc(
  camera: ^Camera,
  pixel_x, pixel_y: f32,
) -> (
  ray_origin: [3]f32,
  ray_dir: [3]f32,
) {
  ndc_x := (2.0 * pixel_x) / f32(camera.extent[0]) - 1.0
  ndc_y := 1.0 - (2.0 * pixel_y) / f32(camera.extent[1])
  inv_proj := linalg.matrix4_inverse(camera_projection_matrix(camera))
  inv_view := linalg.matrix4_inverse(camera_view_matrix(camera))
  ray_eye := inv_proj * [4]f32{ndc_x, ndc_y, -1.0, 1.0}
  ray_eye = {ray_eye.x, ray_eye.y, -1.0, 0.0}
  ray_dir = linalg.normalize((inv_view * ray_eye).xyz)
  return camera.position, ray_dir
}

// ---------- camera pool ----------

camera :: proc(self: ^Manager, handle: CameraHandle) -> (^Camera, bool) #optional_ok {
  return cont.get(self.cameras, handle)
}

main_camera :: proc(self: ^Manager) -> (^Camera, bool) #optional_ok {
  return cont.get(self.cameras, self.main_camera)
}

// Create a perspective camera with its own render targets. Cameras are drawn
// every frame; the main camera is presented to the swapchain.
create_camera :: proc(
  self: ^Manager,
  width, height: u32,
  position: [3]f32 = {0, 0, 3},
  target: [3]f32 = {0, 0, 0},
  fov: f32 = math.PI * 0.5,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> (
  handle: CameraHandle,
  ok: bool,
) #optional_ok {
  gctx := &self.gctx
  cam: ^Camera
  handle, cam = cont.alloc(&self.cameras, CameraHandle) or_return
  cam^ = {
    extent = {width, height},
  }
  camera_set_perspective(cam, fov, near_plane, far_plane)
  camera_look_at(cam, position, target)
  if create_targets(self, gctx, cam) != .SUCCESS {
    destroy_targets(self, gctx, cam)
    cont.free(&self.cameras, handle)
    return {}, false
  }
  return handle, true
}

destroy_camera :: proc(self: ^Manager, handle: CameraHandle) {
  cam := cont.get(self.cameras, handle)
  if cam == nil do return
  destroy_targets(self, &self.gctx, cam)
  cont.free(&self.cameras, handle)
  if handle == self.main_camera do self.main_camera = {}
}

// Look up a camera's attachment texture for `frame_index` (default: the
// frame recorded next).
camera_attachment :: proc(
  self: ^Manager,
  handle: CameraHandle,
  attachment_type: AttachmentType,
  frame_index: Maybe(u32) = nil,
) -> (
  texture: bindless.Texture2DHandle,
  ok: bool,
) #optional_ok {
  cam := cont.get(self.cameras, handle) or_return
  return cam.attachments[attachment_type][frame_index.? or_else self.frame_index], true
}

// Resize a camera's render targets and keep its aspect ratio in sync.
resize_camera :: proc(
  self: ^Manager,
  handle: CameraHandle,
  width, height: u32,
) -> vk.Result {
  gctx := &self.gctx
  cam, ok := cont.get(self.cameras, handle)
  if !ok do return .SUCCESS
  if cam.extent == {width, height} do return .SUCCESS
  cam.extent = {width, height}
  if p, is_persp := &cam.projection.(PerspectiveProjection); is_persp {
    p.aspect_ratio = f32(width) / f32(max(height, 1))
  }
  destroy_targets(self, gctx, cam)
  create_targets(self, gctx, cam) or_return
  log.infof("Camera resized to %dx%d", width, height)
  return .SUCCESS
}

// Swapchain resize: every camera that rendered at the old swapchain extent
// follows it to the new one.
@(private)
resize_swapchain_cameras :: proc(
  self: ^Manager,
  old_extent, new_extent: vk.Extent2D,
) -> vk.Result {
  it := cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) {
    if cam.extent != {old_extent.width, old_extent.height} do continue
    resize_camera(self, handle, new_extent.width, new_extent.height) or_return
  }
  return .SUCCESS
}

// ---------- GPU targets ----------

@(private)
create_targets :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
) -> vk.Result {
  texture_manager := &self.texture_manager
  extent := vk.Extent2D{camera.extent[0], camera.extent[1]}
  Target :: struct {
    type:   AttachmentType,
    format: vk.Format,
  }
  gbuffer := [?]Target {
    {.POSITION, .R32G32B32A32_SFLOAT},
    {.NORMAL, .R8G8B8A8_UNORM},
    {.ALBEDO, .R8G8B8A8_UNORM},
    {.METALLIC_ROUGHNESS, .R8G8B8A8_UNORM},
    {.EMISSIVE, .R8G8B8A8_UNORM},
  }
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    camera.attachments[.FINAL_IMAGE][frame] = bindless.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      gpu.HDR_COLOR_FORMAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return
    for t in gbuffer {
      camera.attachments[t.type][frame] = bindless.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        t.format,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    camera.attachments[.DEPTH][frame] = bindless.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    // Move fresh depth image out of UNDEFINED so first-frame sampling is valid
    if depth := bindless.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][frame],
    ); depth != nil {
      cmd_buf := gpu.begin_single_time_command(gctx) or_return
      gpu.image_discard_barrier(
        cmd_buf,
        depth.image,
        {.DEPTH_STENCIL_ATTACHMENT_READ},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      gpu.end_single_time_command(gctx, &cmd_buf) or_return
    }
  }
  bindless.draw_buffers_init(
    &camera.draws,
    gctx,
    MAX_NODES_IN_SCENE,
    len(bindless.DrawPipeline),
  ) or_return
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    occlusion_culling.setup_pyramid(
      gctx,
      &camera.depth_pyramid[frame],
      texture_manager,
      extent,
    ) or_return
  }
  allocate_descriptors(self, gctx, camera) or_return
  return .SUCCESS
}

@(private)
destroy_targets :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
) {
  for attachment_type in AttachmentType {
    for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
      handle := camera.attachments[attachment_type][frame]
      if handle.index == 0 do continue
      bindless.free_texture_2d(&self.texture_manager, gctx, handle)
    }
  }
  camera.attachments = {}
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    occlusion_culling.destroy_pyramid(
      gctx,
      &camera.depth_pyramid[frame],
      &self.texture_manager,
    )
  }
  camera.depth_pyramid = {}
  bindless.draw_buffers_destroy(&camera.draws, gctx)
  camera.draws = {}
  gpu.free_descriptor_sets(gctx, ..camera.descriptor_set[:])
  for &sets in camera.depth_reduce_descriptor_sets {
    gpu.free_descriptor_sets(gctx, ..sets[:])
  }
  camera.descriptor_set = {}
  camera.depth_reduce_descriptor_sets = {}
}

// Descriptor sets for the culling + depth-reduce pipelines.
@(private = "file")
allocate_descriptors :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
) -> vk.Result {
  texture_manager := &self.texture_manager
  visibility := &self.internal.visibility
  node_data_buffer := &self.internal.node_data_buffer
  mesh_data_buffer := &self.internal.mesh_data_buffer
  camera_buffer := &self.internal.camera_buffer
  for frame_index in 0 ..< gpu.FRAMES_IN_FLIGHT {
    prev_frame_index := (frame_index + gpu.FRAMES_IN_FLIGHT - 1) % gpu.FRAMES_IN_FLIGHT
    pyramid := &camera.depth_pyramid[frame_index]
    prev_pyramid := &camera.depth_pyramid[prev_frame_index]
    prev_depth := bindless.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][prev_frame_index],
    )
    pyramid_image := bindless.get_texture_2d(texture_manager, pyramid.texture)
    prev_pyramid_image := bindless.get_texture_2d(texture_manager, prev_pyramid.texture)
    writes: [occlusion_culling.BINDING_COUNT]struct {
      type: vk.DescriptorType,
      info: union {
        vk.DescriptorBufferInfo,
        vk.DescriptorImageInfo,
      },
    }
    writes[0] = {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)}
    writes[1] = {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)}
    writes[2] = {
      .STORAGE_BUFFER,
      gpu.buffer_info(&camera_buffer.buffers[frame_index]),
    }
    writes[3] = {.STORAGE_BUFFER, gpu.buffer_info(&camera.draws.count[frame_index])}
    writes[4] = {.STORAGE_BUFFER, gpu.buffer_info(&camera.draws.commands[frame_index])}
    writes[5] = {
      .COMBINED_IMAGE_SAMPLER,
      vk.DescriptorImageInfo {
        sampler = visibility.sampler,
        imageView = prev_pyramid_image.view,
        imageLayout = .GENERAL,
      },
    }
    camera.descriptor_set[frame_index] = gpu.create_descriptor_set(
      gctx,
      &visibility.cull_set_layout,
      ..writes[:],
    ) or_return
    for mip in 0 ..< pyramid_image.mip_levels {
      source_info := vk.DescriptorImageInfo {
        sampler     = visibility.sampler,
        imageView   = prev_depth.view if mip == 0 else pyramid.views[mip - 1],
        imageLayout = .GENERAL,
      }
      dest_info := vk.DescriptorImageInfo {
        imageView   = pyramid.views[mip],
        imageLayout = .GENERAL,
      }
      camera.depth_reduce_descriptor_sets[frame_index][mip] =
        gpu.create_descriptor_set(
          gctx,
          &visibility.reduce_set_layout,
          {.COMBINED_IMAGE_SAMPLER, source_info},
          {.STORAGE_IMAGE, dest_info},
        ) or_return
    }
  }
  return .SUCCESS
}
