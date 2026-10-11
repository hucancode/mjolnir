#+private
package render

import geom "../geometry"
import "gpu"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADOW_DEPTH_VERT :: #load("shader/shadow/vert.spv")

// Nodes drawn into shadow maps: visible casters that are not drawn by a
// forward pipeline.
SHADOW_INCLUDE :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
SHADOW_EXCLUDE :: NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_SPRITE}

// One depth render into a shadow map: a spot or directional light renders
// one view, a point light one per cube face. Cube faces are mirror images of
// an ordinary view, so they keep the viewport unflipped to match cube
// sampling and wind clockwise.
ShadowView :: struct {
  view_projection: matrix[4, 4]f32,
  target:          vk.ImageView,
  flip_y:          bool,
  front_face:      vk.FrontFace,
}

// A view as the cull shader reads it: normalized frustum planes.
ShadowViewGPU :: struct {
  planes: [6][4]f32,
}

ShadowCullPushConstants :: struct {
  node_count:    u32,
  view_count:    u32,
  max_draws:     u32, // per view
  include_flags: u32,
  exclude_flags: u32,
}

ShadowDepthPushConstants :: struct {
  view_projection: matrix[4, 4]f32,
}

// Depth passes bind every mesh set except the camera.
SHADOW_SETS :: MESH_SETS - {.CAMERA}

// One cull dispatch per frame tests every node against every view and appends
// the visible casters to that view's draw list: view v owns
// draws.count[v] and draws.commands[v*SHADOW_VIEW_MAX_DRAWS:].
ShadowSystem :: struct {
  cull_descriptor_layout: vk.DescriptorSetLayout,
  cull_descriptor_sets:   [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
  cull_pipeline_layout:   vk.PipelineLayout,
  cull_pipeline:          vk.Pipeline,
  depth_pipeline_layout:  vk.PipelineLayout,
  depth_pipeline:         vk.Pipeline,
  views:                  [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(ShadowViewGPU),
  draws:                  DrawBuffers,
}

// Per-frame shadow math for one light, shared by the depth pass and the
// lighting pass. A point light uses `projection` for every cube face (the
// face views come from point_face_view) and leaves `view_projection` unset.
ShadowFrameInfo :: struct {
  view_projection: matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  near, far:       f32,
}

shadow_safe_normalize :: proc(v: [3]f32, fallback: [3]f32) -> [3]f32 {
  len_sq := linalg.dot(v, v)
  if len_sq < 1e-6 do return fallback
  return linalg.normalize(v)
}

shadow_make_light_view :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  forward := shadow_safe_normalize(direction, {0, -1, 0})
  up := [3]f32{0, 1, 0}
  if math.abs(linalg.dot(forward, up)) > 0.95 {
    up = {0, 0, 1}
  }
  target := position + forward
  return linalg.matrix4_look_at(position, target, up)
}

shadow_matrices_spot :: proc(
  position, direction: [3]f32,
  radius, angle_outer: f32,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius)
  view = shadow_make_light_view(position, direction)
  fovy := max(angle_outer * 2.0, 0.001)
  projection = geom.make_perspective_matrix(fovy, 1.0, near, far)
  return
}

shadow_matrices_directional :: proc(
  position, direction: [3]f32,
  radius: f32,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius * 2.0)
  camera_pos := position - direction * radius
  view = shadow_make_light_view(camera_pos, direction)
  half_extent := max(radius, 0.5)
  projection = geom.make_ortho_matrix(
    -half_extent,
    half_extent,
    -half_extent,
    half_extent,
    near,
    far,
  )
  return
}

shadow_projection_point :: proc(
  radius: f32,
) -> (
  projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius)
  projection = geom.make_perspective_matrix(
    f32(math.PI * 0.5),
    1.0,
    near,
    far,
  )
  return
}

// View from `position` through cube face `face` (+X, -X, +Y, -Y, +Z, -Z),
// oriented so that, with an unflipped viewport, the rendered image lands
// where Vulkan's cube sampling reads it.
point_face_view :: proc(position: [3]f32, face: int) -> matrix[4, 4]f32 {
  @(static, rodata)
  FACES := [6][2][3]f32 {
    {{1, 0, 0}, {0, -1, 0}},
    {{-1, 0, 0}, {0, -1, 0}},
    {{0, 1, 0}, {0, 0, 1}},
    {{0, -1, 0}, {0, 0, -1}},
    {{0, 0, 1}, {0, -1, 0}},
    {{0, 0, -1}, {0, -1, 0}},
  }
  return linalg.matrix4_look_at(position, position + FACES[face][0], FACES[face][1])
}

shadow_init :: proc(r: ^Manager) -> (ret: vk.Result) {
  self := &r.internal.shadow
  gctx := &r.gctx
  defer if ret != .SUCCESS do shadow_shutdown(self, gctx)
  self.cull_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}}, // nodes
    {.STORAGE_BUFFER, {.COMPUTE}}, // meshes
    {.STORAGE_BUFFER, {.COMPUTE}}, // views
    {.STORAGE_BUFFER, {.COMPUTE}}, // draw counts
    {.STORAGE_BUFFER, {.COMPUTE}}, // draw commands
  ) or_return
  self.cull_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.COMPUTE}, size = size_of(ShadowCullPushConstants)},
    self.cull_descriptor_layout,
  ) or_return
  self.cull_pipeline = gpu.create_compute_pipeline(
    gctx,
    #load("shader/shadow/cull.spv"),
    self.cull_pipeline_layout,
  ) or_return
  draw_buffers_init(&self.draws, gctx, SHADOW_VIEW_MAX_DRAWS, lists = MAX_SHADOW_VIEWS) or_return
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    self.views[frame] = gpu.create_mutable_buffer(
      gctx,
      ShadowViewGPU,
      MAX_SHADOW_VIEWS,
      {.STORAGE_BUFFER},
    ) or_return
    self.cull_descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      &self.cull_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&r.internal.node_data_buffer.buffers[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&r.internal.mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&self.views[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&self.draws.count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&self.draws.commands[frame])},
    ) or_return
  }
  self.depth_pipeline_layout = create_scene_pipeline_layout(
    r,
    SHADOW_SETS,
    {stageFlags = {.VERTEX}, size = size_of(ShadowDepthPushConstants)},
  ) or_return
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .FRONT_FACE}
  self.depth_pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = SHADOW_DEPTH_VERT,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = POSITION_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      raster = {polygonMode = .FILL, cullMode = {.BACK}},
      depth = gpu.READ_WRITE_DEPTH_STATE,
      depth_format = .D32_SFLOAT,
      dynamic_states = dynamic_states[:],
      layout = self.depth_pipeline_layout,
    },
  ) or_return
  return .SUCCESS
}

shadow_shutdown :: proc(self: ^ShadowSystem, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.cull_pipeline_layout, nil)
  gpu.free_descriptor_sets(gctx, ..self.cull_descriptor_sets[:])
  for &views in self.views do gpu.mutable_buffer_destroy(gctx.device, &views)
  draw_buffers_destroy(&self.draws, gctx)
  vk.DestroyDescriptorSetLayout(gctx.device, self.cull_descriptor_layout, nil)
  self^ = {}
}

shadow_view_count :: proc(sm: ^ShadowMap) -> int {
  return 6 if sm.cube else 1
}

// View `face` of a light's shadow map `depth`.
shadow_view :: proc(fl: ^FrameLight, depth: ^gpu.Image, face: int) -> ShadowView {
  if fl.shadow_map.cube {
    return {
      view_projection = fl.info.projection * point_face_view(fl.params.position, face),
      target = depth.face_views[face],
      flip_y = false,
      front_face = .CLOCKWISE,
    }
  }
  return {
    view_projection = fl.info.view_projection,
    target = depth.view,
    flip_y = true,
    front_face = .COUNTER_CLOCKWISE,
  }
}

// Render every shadow map of this frame: collect the views of all lights
// with a map, cull every node against all of them in one dispatch, then draw
// each view's list into its target.
shadow_record :: proc(r: ^Manager, frame_index: u32) {
  self := &r.internal.shadow
  cmd := r.internal.command_buffers[frame_index]
  views: [MAX_SHADOW_VIEWS]ShadowView
  view_count := 0
  gpu_views := gpu.get_all(&self.views[frame_index])
  for &fl in r.internal.frame_lights {
    sm := fl.shadow_map
    if sm == nil do continue
    depth :=
      get_texture_cube(&r.texture_manager, sm.textures[frame_index]) if sm.cube else get_texture_2d(&r.texture_manager, sm.textures[frame_index])
    if depth == nil do continue
    count := shadow_view_count(sm)
    gpu.image_discard_barrier(
      cmd,
      depth.image,
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      {.EARLY_FRAGMENT_TESTS},
      {.DEPTH},
      layer_count = u32(count),
    )
    for face in 0 ..< count {
      views[view_count] = shadow_view(&fl, depth, face)
      gpu_views[view_count] = {geom.make_frustum(views[view_count].view_projection).planes}
      view_count += 1
    }
  }
  if view_count == 0 do return
  commands := &self.draws.commands[frame_index]
  counts := &self.draws.count[frame_index]
  vk.CmdFillBuffer(cmd, counts.buffer, 0, vk.DeviceSize(counts.bytes_count), 0)
  gpu.buffer_barrier(
    cmd,
    counts.buffer,
    vk.DeviceSize(counts.bytes_count),
    {.TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.TRANSFER},
    {.COMPUTE_SHADER},
  )
  gpu.bind_pipeline(cmd, .COMPUTE, self.cull_pipeline, self.cull_pipeline_layout, self.cull_descriptor_sets[frame_index])
  cull := ShadowCullPushConstants {
    node_count    = r.node_count,
    view_count    = u32(view_count),
    max_draws     = SHADOW_VIEW_MAX_DRAWS,
    include_flags = transmute(u32)SHADOW_INCLUDE,
    exclude_flags = transmute(u32)SHADOW_EXCLUDE,
  }
  vk.CmdPushConstants(cmd, self.cull_pipeline_layout, {.COMPUTE}, 0, size_of(cull), &cull)
  vk.CmdDispatch(cmd, (r.node_count + 63) / 64, 1, 1)
  indirect_barrier(cmd, commands, counts)
  // bound state outlives the rendering scopes below
  bind_scene(r, cmd, frame_index, self.depth_pipeline, self.depth_pipeline_layout, SHADOW_SETS)
  extent := vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
  stride :: size_of(vk.DrawIndexedIndirectCommand)
  for &v, i in views[:view_count] {
    gpu.begin_rendering(cmd, extent, gpu.create_depth_attachment(v.target))
    gpu.set_viewport_scissor(cmd, extent, flip_y = v.flip_y)
    vk.CmdSetFrontFace(cmd, v.front_face)
    push := ShadowDepthPushConstants{v.view_projection}
    vk.CmdPushConstants(cmd, self.depth_pipeline_layout, {.VERTEX}, 0, size_of(push), &push)
    vk.CmdDrawIndexedIndirectCount(
      cmd,
      commands.buffer,
      vk.DeviceSize(i * SHADOW_VIEW_MAX_DRAWS * stride),
      counts.buffer,
      vk.DeviceSize(i * size_of(u32)),
      SHADOW_VIEW_MAX_DRAWS,
      stride,
    )
    vk.CmdEndRendering(cmd)
  }
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
  )
}
