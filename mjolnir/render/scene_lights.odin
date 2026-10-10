package render

import "bindless"
import "gpu"
import "core:log"
import "core:slice"
import "shadow"
import vk "vendor:vulkan"

@(private)
init_light_state :: proc(self: ^Manager) {
  self.internal.lights = make(map[u32]Light)
  self.internal.shadow_maps = make(map[u32]ShadowMap)
}

@(private)
destroy_light_state :: proc(self: ^Manager) {
  delete(self.internal.lights)
  delete(self.internal.shadow_maps)
}

// Release every light's shadow resources and forget all lights; the maps
// themselves stay allocated for reuse by the next setup.
@(private)
release_all_light_shadows :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for light_node_index in self.internal.lights {
    release_shadow(self, gctx, light_node_index)
  }
  clear(&self.internal.lights)
}

@(private)
release_shadow :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  sm, ok := &render.internal.shadow_maps[light_node_index]
  if !ok do return
  for texture in sm.textures {
    if sm.cube {
      bindless.free_texture_cube(&render.texture_manager, gctx, texture)
    } else {
      bindless.free_texture_2d(&render.texture_manager, gctx, texture)
    }
  }
  bindless.draw_buffers_destroy(&sm.draws, gctx)
  delete_key(&render.internal.shadow_maps, light_node_index)
}

// Make sure the light has shadow resources of the right kind: a cube map for
// point lights, a 2D map otherwise.
@(private)
ensure_shadow_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
  cube: bool,
) -> (
  ret: vk.Result,
) {
  if existing, ok := render.internal.shadow_maps[light_node_index]; ok {
    if existing.cube == cube do return .SUCCESS
    release_shadow(render, gctx, light_node_index)
  }
  render.internal.shadow_maps[light_node_index] = {
    cube = cube,
  }
  sm := &render.internal.shadow_maps[light_node_index]
  defer if ret != .SUCCESS do release_shadow(render, gctx, light_node_index)
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    if cube {
      texture := bindless.allocate_texture_cube(
        &render.texture_manager,
        gctx,
        SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
      sm.textures[frame] = transmute(Handle)texture
    } else {
      texture := bindless.allocate_texture_2d(
        &render.texture_manager,
        gctx,
        vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
      sm.textures[frame] = transmute(Handle)texture
    }
  }
  bindless.draw_buffers_init(&sm.draws, gctx, MAX_NODES_IN_SCENE) or_return
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    sm.descriptor_sets[frame] = shadow.create_per_light_descriptor(
      &render.internal.shadow,
      gctx,
      gpu.buffer_info(&render.internal.node_data_buffer.buffer),
      gpu.buffer_info(&render.internal.mesh_data_buffer.buffer),
      gpu.buffer_info(&sm.draws.count[frame]),
      gpu.buffer_info(&sm.draws.commands[frame]),
    ) or_return
  }
  return .SUCCESS
}

@(private)
upsert_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
  light_data: ^Light,
  cast_shadow: bool,
) -> vk.Result {
  render.internal.lights[light_node_index] = light_data^
  if !cast_shadow {
    release_shadow(render, gctx, light_node_index)
    return .SUCCESS
  }
  _, is_point := light_data.(PointLight)
  if result := ensure_shadow_resource(render, gctx, light_node_index, is_point);
     result != .SUCCESS {
    log.warnf(
      "Failed to allocate shadow resources for light %d: %v (shadows disabled)",
      light_node_index,
      result,
    )
  }
  return .SUCCESS
}

// Build per-frame shadow info for every active light. Computed once per
// frame; consumed by depth dispatch and lighting pass to avoid duplicating
// matrix derivation across passes.
@(private)
build_shadow_cache :: proc(
  self: ^Manager,
) -> map[u32]shadow.ShadowFrameInfo {
  cache := make(
    map[u32]shadow.ShadowFrameInfo,
    len(self.internal.lights),
    context.temp_allocator,
  )
  for idx, light in self.internal.lights {
    info: shadow.ShadowFrameInfo
    switch variant in light {
    case SpotLight:
      view, projection, near, far := shadow.matrices_spot(
        variant.position,
        variant.direction,
        variant.radius,
        variant.angle_outer,
      )
      info = {projection * view, projection, near, far}
    case DirectionalLight:
      view, projection, near, far := shadow.matrices_directional(
        variant.position,
        variant.direction,
        variant.radius,
      )
      info = {projection * view, projection, near, far}
    case PointLight:
      projection, near, far := shadow.projection_point(variant.radius)
      info = {{}, projection, near, far}
    }
    cache[idx] = info
  }
  return cache
}

// Sorted light node indices, truncated to MAX_LIGHTS. Shared by shadow depth
// and lighting passes so iteration order is stable across passes.
@(private)
sorted_light_indices :: proc(self: ^Manager) -> []u32 {
  indices := make(
    [dynamic]u32,
    0,
    len(self.internal.lights),
    context.temp_allocator,
  )
  for light_node_index in self.internal.lights {
    append(&indices, light_node_index)
  }
  slice.sort(indices[:])
  return indices[:min(len(indices), int(MAX_LIGHTS))]
}

@(private)
remove_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  release_shadow(render, gctx, light_node_index)
  delete_key(&render.internal.lights, light_node_index)
}
