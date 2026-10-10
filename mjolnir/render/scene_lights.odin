package render

import "bindless"
import "gpu"
import "core:log"
import "core:slice"
import "direct_light"
import "shadow"
import vk "vendor:vulkan"

// Shadow resources of one slot. Each frame the first MAX_SHADOW_MAPS shadow
// casters, in slot order, take slots 0, 1, ... Draw buffers and descriptor
// sets are created on first use and live until shutdown. Textures are
// level-lifetime: a cube map for a point light, a 2D map otherwise,
// reallocated when the slot changes to a light of the other kind.
@(private)
ShadowMap :: struct {
  cube:            bool,
  textures:        [gpu.FRAMES_IN_FLIGHT]Handle,
  draws:           bindless.DrawBuffers,
  descriptor_sets: [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

// One light as the shadow depth and lighting passes consume it this frame.
@(private)
FrameLight :: struct {
  type:       direct_light.LightType,
  params:     direct_light.Light,
  shadow_map: ^ShadowMap, // nil when the light casts no shadow
  info:       shadow.ShadowFrameInfo,
}

@(private)
destroy_light_state :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for &sm in self.internal.shadow_maps {
    bindless.draw_buffers_destroy(&sm.draws, gctx)
    gpu.free_descriptor_sets(gctx, ..sm.descriptor_sets[:])
  }
  delete(self.internal.light_slots)
  delete(self.internal.frame_lights)
}

// Rebuild frame_lights from the light slots: lights sorted by slot and
// truncated to MAX_LIGHTS, with shadow matrices derived once so both passes
// see the same lights in the same order. Caller holds the staging mutex.
@(private)
collect_lights :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  slots := make([dynamic]u32, 0, len(self.internal.light_slots), context.temp_allocator)
  for slot in self.internal.light_slots do append(&slots, slot)
  slice.sort(slots[:])
  clear(&self.internal.frame_lights)
  shadow_count := 0
  for slot in slots {
    if len(self.internal.frame_lights) == MAX_LIGHTS do break
    inst := &self.instances[slot]
    fl, cast_shadow := frame_light(inst.attachment, inst.world_matrix) or_continue
    if cast_shadow && shadow_count < MAX_SHADOW_MAPS {
      sm := &self.internal.shadow_maps[shadow_count]
      if res := ensure_shadow_map(self, gctx, sm, fl.type == .POINT); res == .SUCCESS {
        fl.shadow_map = sm
        shadow_count += 1
      } else {
        log.warnf("Failed to allocate a shadow map for light %d: %v", slot, res)
      }
    }
    append(&self.internal.frame_lights, fl)
  }
}

// The light at a slot placed at `world_matrix`. ok=false when the attachment
// is not a light or the light is disabled.
@(private = "file")
frame_light :: proc(
  a: Attachment,
  world_matrix: matrix[4, 4]f32,
) -> (
  fl: FrameLight,
  cast_shadow: bool,
  ok: bool,
) {
  position := world_matrix[3].xyz
  direction := shadow.safe_normalize(world_matrix[2].xyz, {0, -1, 0})
  #partial switch att in a {
  case PointLightAttachment:
    if att.disabled do return
    fl.type = .POINT
    fl.params = {color = att.color, position = position, radius = att.radius}
    projection, near, far := shadow.projection_point(att.radius)
    fl.info = {{}, projection, near, far}
    cast_shadow = att.cast_shadow
  case SpotLightAttachment:
    if att.disabled do return
    fl.type = .SPOT
    fl.params = {
      color       = att.color,
      position    = position,
      direction   = direction,
      radius      = att.radius,
      angle_inner = att.angle_inner,
      angle_outer = att.angle_outer,
    }
    view, projection, near, far := shadow.matrices_spot(
      position,
      direction,
      att.radius,
      att.angle_outer,
    )
    fl.info = {projection * view, projection, near, far}
    cast_shadow = att.cast_shadow
  case DirectionalLightAttachment:
    if att.disabled do return
    fl.type = .DIRECTIONAL
    fl.params = {color = att.color, direction = direction}
    view, projection, near, far := shadow.matrices_directional(
      position,
      direction,
      att.radius,
    )
    fl.info = {projection * view, projection, near, far}
    cast_shadow = att.cast_shadow
  case:
    return
  }
  ok = true
  return
}

// Give the slot its draw buffers and textures of the requested kind.
@(private = "file")
ensure_shadow_map :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  sm: ^ShadowMap,
  cube: bool,
) -> (
  ret: vk.Result,
) {
  if sm.descriptor_sets[0] == 0 {
    defer if ret != .SUCCESS {
      bindless.draw_buffers_destroy(&sm.draws, gctx)
      gpu.free_descriptor_sets(gctx, ..sm.descriptor_sets[:])
      sm.descriptor_sets = {}
    }
    bindless.draw_buffers_init(&sm.draws, gctx, MAX_NODES_IN_SCENE) or_return
    for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
      sm.descriptor_sets[frame] = shadow.create_per_light_descriptor(
        &self.internal.shadow,
        gctx,
        gpu.buffer_info(&self.internal.node_data_buffer.buffer),
        gpu.buffer_info(&self.internal.mesh_data_buffer.buffer),
        gpu.buffer_info(&sm.draws.count[frame]),
        gpu.buffer_info(&sm.draws.commands[frame]),
      ) or_return
    }
  }
  if sm.cube == cube && !slice.contains(sm.textures[:], Handle{}) do return .SUCCESS
  for &texture in sm.textures {
    if texture == {} do continue
    if sm.cube {
      bindless.free_texture_cube(&self.texture_manager, gctx, texture)
    } else {
      bindless.free_texture_2d(&self.texture_manager, gctx, texture)
    }
    texture = {}
  }
  sm.cube = cube
  for &texture in sm.textures {
    if cube {
      texture = Handle(
        bindless.allocate_texture_cube(
          &self.texture_manager,
          gctx,
          SHADOW_MAP_SIZE,
          .D32_SFLOAT,
          {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
        ) or_return,
      )
    } else {
      texture = Handle(
        bindless.allocate_texture_2d(
          &self.texture_manager,
          gctx,
          vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
          .D32_SFLOAT,
          {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
        ) or_return,
      )
    }
  }
  return .SUCCESS
}
