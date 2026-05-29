package render

import "../gpu"
import "core:log"
import shadow_culling_system "shadow_culling"
import shadow_sphere_culling_system "shadow_sphere_culling"
import vk "vendor:vulkan"

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
