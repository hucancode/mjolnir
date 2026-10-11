package render

import "gpu"
import "core:log"
import ba "core:container/bit_array"
import "core:slice"
import vk "vendor:vulkan"

// Shadow resources of one shadow map. A shadow-casting light keeps the map it
// was given for as long as it casts; new casters, in slot order, take a free
// map of their kind first, so maps rarely change kind. Draw buffers and
// descriptor sets are created on first use and live until shutdown. Textures
// are level-lifetime: a cube map for a point light, a 2D map otherwise,
// reallocated when the map goes to a light of the other kind.
@(private)
ShadowMap :: struct {
  // light slot + 1 of the light using this map; 0 when free
  owner:           u32,
  cube:            bool,
  textures:        [gpu.FRAMES_IN_FLIGHT]Handle,
  draws:           DrawBuffers,
  descriptor_sets: [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

// One light as the shadow depth and lighting passes consume it this frame.
@(private)
FrameLight :: struct {
  type:       LightType,
  params:     DirectLight,
  shadow_map: ^ShadowMap, // nil when the light casts no shadow
  info:       ShadowFrameInfo,
}

@(private)
destroy_light_state :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for &sm in self.internal.shadow_maps {
    draw_buffers_destroy(&sm.draws, gctx)
    gpu.free_descriptor_sets(gctx, ..sm.descriptor_sets[:])
  }
  delete(self.internal.frame_lights)
}

// A shadow-casting light this frame.
@(private = "file")
Caster :: struct {
  light: int, // index into frame_lights
  owner: u32, // light slot + 1, as in ShadowMap.owner
}

// Rebuild frame_lights from the light slots: lights in slot order, truncated
// to MAX_LIGHTS, with shadow matrices derived once so both passes see the same
// lights in the same order. Caller holds the staging mutex.
@(private)
collect_lights :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  clear(&self.internal.frame_lights)
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  it := ba.make_iterator(&self.internal.staging.lights)
  for slot in ba.iterate_by_set(&it) {
    if len(self.internal.frame_lights) == MAX_LIGHTS do break
    inst := &self.instances[slot]
    fl, cast_shadow := frame_light(inst.attachment, inst.world_matrix) or_continue
    if cast_shadow {
      casters[caster_count] = {len(self.internal.frame_lights), u32(slot) + 1}
      caster_count += 1
    }
    append(&self.internal.frame_lights, fl)
  }
  maps := &self.internal.shadow_maps
  claimed: [MAX_SHADOW_MAPS]bool
  // Casters keep the map they had; the rest wait for a free one.
  waiting: [MAX_LIGHTS]Caster
  waiting_count := 0
  for c in casters[:caster_count] {
    found := false
    for &sm, m in maps do if sm.owner == c.owner {
      claimed[m] = true
      found = true
      give_shadow_map(self, gctx, m, c)
      break
    }
    if !found {
      waiting[waiting_count] = c
      waiting_count += 1
    }
  }
  for &sm, m in maps do if !claimed[m] do sm.owner = 0
  // A free map of the caster's kind avoids reallocating its textures.
  for c in waiting[:waiting_count] {
    cube := self.internal.frame_lights[c.light].type == .POINT
    best := -1
    for sm, m in maps {
      if claimed[m] do continue
      if best < 0 || (sm.cube == cube && maps[best].cube != cube) do best = m
    }
    if best < 0 do break
    claimed[best] = true
    maps[best].owner = c.owner
    give_shadow_map(self, gctx, best, c)
  }
}

// Point a caster's frame light at shadow map `m`, giving the map the
// caster's kind.
@(private = "file")
give_shadow_map :: proc(self: ^Manager, gctx: ^gpu.GPUContext, m: int, c: Caster) {
  fl := &self.internal.frame_lights[c.light]
  sm := &self.internal.shadow_maps[m]
  if res := ensure_shadow_map(self, gctx, sm, fl.type == .POINT); res != .SUCCESS {
    log.warnf("Failed to allocate a shadow map for light %d: %v", c.owner - 1, res)
    return
  }
  fl.shadow_map = sm
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
  direction := shadow_safe_normalize(world_matrix[2].xyz, {0, -1, 0})
  #partial switch att in a {
  case PointLightAttachment:
    if att.disabled do return
    fl.type = .POINT
    fl.params = {color = att.color, position = position, radius = att.radius}
    projection, near, far := shadow_projection_point(att.radius)
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
    view, projection, near, far := shadow_matrices_spot(
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
    view, projection, near, far := shadow_matrices_directional(
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
      draw_buffers_destroy(&sm.draws, gctx)
      gpu.free_descriptor_sets(gctx, ..sm.descriptor_sets[:])
      sm.descriptor_sets = {}
    }
    draw_buffers_init(&sm.draws, gctx, MAX_NODES_IN_SCENE) or_return
    for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
      sm.descriptor_sets[frame] = shadow_create_per_light_descriptor(
        &self.internal.shadow,
        gctx,
        gpu.buffer_info(&self.internal.node_data_buffer.buffers[frame]),
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
      free_texture_cube(&self.texture_manager, gctx, texture)
    } else {
      free_texture_2d(&self.texture_manager, gctx, texture)
    }
    texture = {}
  }
  sm.cube = cube
  for &texture in sm.textures {
    if cube {
      texture = Handle(
        allocate_texture_cube(
          &self.texture_manager,
          gctx,
          SHADOW_MAP_SIZE,
          .D32_SFLOAT,
          {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
        ) or_return,
      )
    } else {
      texture = Handle(
        allocate_texture_2d(
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
