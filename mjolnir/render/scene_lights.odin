package render

import "../gpu"
import "core:log"
import "core:slice"
import shadow_culling_system "shadow_culling"
import shadow_render_system "shadow_render"
import shadow_sphere_culling_system "shadow_sphere_culling"
import vk "vendor:vulkan"

@(private)
init_light_state :: proc(self: ^Manager) {
  self.internal.lights = make(map[u32]Light)
  self.internal.shadow_maps = make(map[u32]ShadowMap)
  self.internal.shadow_map_cubes = make(map[u32]ShadowMapCube)
}

@(private)
destroy_light_state :: proc(self: ^Manager) {
  delete(self.internal.lights)
  delete(self.internal.shadow_maps)
  delete(self.internal.shadow_map_cubes)
}

// Release per-light shadow GPU resources without freeing the light state
// maps themselves. Used during teardown so a future setup can reuse the maps.
@(private)
release_all_light_shadows :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for light_node_index, light in self.internal.lights {
    switch variant in light {
    case PointLight:
      release_shadow_cube(self, gctx, light_node_index)
    case SpotLight:
      release_shadow_2d(self, gctx, light_node_index)
    case DirectionalLight:
      release_shadow_2d(self, gctx, light_node_index)
    }
  }
  clear(&self.internal.lights)
}

@(private)
release_shadow_2d :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  shadow, ok := &render.internal.shadow_maps[light_node_index]
  if !ok do return
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    gpu.free_texture_2d(
      &render.texture_manager,
      gctx,
      shadow.shadow_map_2d[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
  delete_key(&render.internal.shadow_maps, light_node_index)
}

@(private)
release_shadow_cube :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  shadow, ok := &render.internal.shadow_map_cubes[light_node_index]
  if !ok do return
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    gpu.free_texture_cube(
      &render.texture_manager,
      gctx,
      shadow.shadow_map_cube[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
  delete_key(&render.internal.shadow_map_cubes, light_node_index)
}

@(private)
ensure_shadow_2d_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) -> vk.Result {
  if light_node_index in render.internal.shadow_maps do return .SUCCESS
  sm: ShadowMap
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    sm.shadow_map_2d[frame] = gpu.allocate_texture_2d(
      &render.texture_manager,
      gctx,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    sm.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    sm.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = shadow_culling_system.create_per_light_descriptor(
      &render.internal.shadow_culling,
      gctx,
      gpu.buffer_info(&render.internal.node_data_buffer.buffer),
      gpu.buffer_info(&render.internal.mesh_data_buffer.buffer),
      gpu.buffer_info(&sm.draw_count[frame]),
      gpu.buffer_info(&sm.draw_commands[frame]),
    ) or_return
  }
  render.internal.shadow_maps[light_node_index] = sm
  return .SUCCESS
}

@(private)
ensure_shadow_cube_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) -> vk.Result {
  if light_node_index in render.internal.shadow_map_cubes do return .SUCCESS
  sm: ShadowMapCube
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    sm.shadow_map_cube[frame] = gpu.allocate_texture_cube(
      &render.texture_manager,
      gctx,
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    sm.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    sm.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = shadow_sphere_culling_system.create_per_light_descriptor(
      &render.internal.shadow_sphere_culling,
      gctx,
      gpu.buffer_info(&render.internal.node_data_buffer.buffer),
      gpu.buffer_info(&render.internal.mesh_data_buffer.buffer),
      gpu.buffer_info(&sm.draw_count[frame]),
      gpu.buffer_info(&sm.draw_commands[frame]),
    ) or_return
  }
  render.internal.shadow_map_cubes[light_node_index] = sm
  return .SUCCESS
}

upsert_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
  light_data: ^Light,
  cast_shadow: bool,
) -> vk.Result {
  render.internal.lights[light_node_index] = light_data^
  if cast_shadow {
    shadow_result: vk.Result
    switch variant in light_data^ {
    case PointLight:
      shadow_result = ensure_shadow_cube_resource(render, gctx, light_node_index)
    case SpotLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, light_node_index)
    case DirectionalLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, light_node_index)
    }
    if shadow_result != .SUCCESS {
      log.warnf(
        "Failed to allocate shadow resources for light %d: %v (shadows disabled)",
        light_node_index,
        shadow_result,
      )
    }
  } else {
    switch variant in light_data^ {
    case PointLight:
      release_shadow_cube(render, gctx, light_node_index)
    case SpotLight:
      release_shadow_2d(render, gctx, light_node_index)
    case DirectionalLight:
      release_shadow_2d(render, gctx, light_node_index)
    }
  }
  return .SUCCESS
}

// Build per-frame shadow info for every active light. Computed once per
// frame; consumed by depth dispatch and lighting pass to avoid duplicating
// matrix derivation across passes.
@(private)
build_shadow_cache :: proc(
  self: ^Manager,
) -> map[u32]shadow_render_system.ShadowFrameInfo {
  cache := make(
    map[u32]shadow_render_system.ShadowFrameInfo,
    len(self.internal.lights),
    context.temp_allocator,
  )
  for idx, light in self.internal.lights {
    info: shadow_render_system.ShadowFrameInfo
    switch variant in light {
    case SpotLight:
      view, projection, near, far := shadow_render_system.matrices_spot(
        variant.position,
        variant.direction,
        variant.radius,
        variant.angle_outer,
      )
      info = {projection * view, projection, near, far}
    case DirectionalLight:
      view, projection, near, far := shadow_render_system.matrices_directional(
        variant.position,
        variant.direction,
        variant.radius,
      )
      info = {projection * view, projection, near, far}
    case PointLight:
      projection, near, far := shadow_render_system.projection_point(variant.radius)
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

remove_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  light, ok := render.internal.lights[light_node_index]
  if !ok do return
  switch variant in light {
  case PointLight:
    release_shadow_cube(render, gctx, light_node_index)
  case SpotLight:
    release_shadow_2d(render, gctx, light_node_index)
  case DirectionalLight:
    release_shadow_2d(render, gctx, light_node_index)
  }
  delete_key(&render.internal.lights, light_node_index)
}
