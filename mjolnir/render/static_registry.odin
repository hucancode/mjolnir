package render

import alg "../algebra"
import "../gpu"
import cmd "../gpu/ui"
import "ambient"
import rd "data"
import "direct_light"
import "geometry"
import rg "graph"
import "line_strip"
import "occlusion_culling"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import "random_color"
import "shadow"
import "sprite"
import "transparent"
import ui_render "ui"
import vk "vendor:vulkan"
import "wireframe"

FrameGraphPassId :: enum u8 {
  SHADOW_COMPUTE,
  SHADOW_DEPTH,
  PARTICLE_SIMULATION,
  VISIBILITY_CULLING,
  DEPTH_PREPASS,
  DEPTH_PYRAMID,
  GEOMETRY,
  AMBIENT,
  DIRECT_LIGHT,
  PARTICLES_RENDER,
  TRANSPARENT_RENDER,
  WIREFRAME_RENDER,
  RANDOM_COLOR_RENDER,
  LINE_STRIP_RENDER,
  SPRITE_RENDER,
  DEBUG,
  POST_PROCESS,
  UI,
}

FrameGraphInstanceGroup :: enum u8 {
  ALWAYS,
  ACTIVE_LIGHTS,
  CULLING_CAMERAS,
  DEPTH_CAMERAS,
  DEPTH_PYRAMID_CAMERAS,
  GEOMETRY_CAMERAS,
  LIGHTING_CAMERAS,
  PARTICLES_CAMERAS,
  TRANSPARENCY_CAMERAS,
  DEBUG_CAMERAS,
}

FrameGraphTemplateRegistryEntry :: struct {
  id:             FrameGraphPassId,
  decl:           rg.PassTemplate,
  execute:        rg.PassExecuteProc,
  instance_group: FrameGraphInstanceGroup,
}

FrameGraphTemplateBuildInput :: struct {
  active_light_slots:    []u32,
  culling_cameras:       []u32,
  depth_cameras:         []u32,
  depth_pyramid_cameras: []u32,
  geometry_cameras:      []u32,
  lighting_cameras:      []u32,
  particles_cameras:     []u32,
  transparency_cameras:  []u32,
  debug_cameras:         []u32,
  main_camera_index:     u32,
}

FrameGraphExecutionPayload :: struct {
  main_camera_index:      u32,
  active_lights:          []rd.LightHandle,
  shadow_texture_indices: [rd.MAX_LIGHTS]u32,
  swapchain_view:         vk.ImageView,
  swapchain_extent:       vk.Extent2D,
  ui_commands:            []cmd.RenderCommand,
}

STATIC_TEMPLATES := [FrameGraphPassId]FrameGraphTemplateRegistryEntry {
  .SHADOW_COMPUTE = {
    id = .SHADOW_COMPUTE,
    decl = SHADOW_COMPUTE_PASS,
    execute = frame_graph_shadow_compute_execute,
    instance_group = .ACTIVE_LIGHTS,
  },
  .SHADOW_DEPTH = {
    id = .SHADOW_DEPTH,
    decl = SHADOW_DEPTH_PASS,
    execute = frame_graph_shadow_depth_execute,
    instance_group = .ACTIVE_LIGHTS,
  },
  .PARTICLE_SIMULATION = {
    id = .PARTICLE_SIMULATION,
    decl = PARTICLE_SIMULATION_PASS,
    execute = frame_graph_particle_simulation_execute,
    instance_group = .ALWAYS,
  },
  .VISIBILITY_CULLING = {
    id = .VISIBILITY_CULLING,
    decl = VISIBILITY_CULLING_PASS,
    execute = frame_graph_visibility_culling_execute,
    instance_group = .CULLING_CAMERAS,
  },
  .DEPTH_PREPASS = {
    id = .DEPTH_PREPASS,
    decl = DEPTH_PREPASS,
    execute = frame_graph_depth_prepass_execute,
    instance_group = .DEPTH_CAMERAS,
  },
  .DEPTH_PYRAMID = {
    id = .DEPTH_PYRAMID,
    decl = DEPTH_PYRAMID_PASS,
    execute = frame_graph_depth_pyramid_execute,
    instance_group = .DEPTH_PYRAMID_CAMERAS,
  },
  .GEOMETRY = {
    id = .GEOMETRY,
    decl = GEOMETRY_PASS,
    execute = frame_graph_geometry_execute,
    instance_group = .GEOMETRY_CAMERAS,
  },
  .AMBIENT = {
    id = .AMBIENT,
    decl = AMBIENT_PASS,
    execute = frame_graph_ambient_execute,
    instance_group = .LIGHTING_CAMERAS,
  },
  .DIRECT_LIGHT = {
    id = .DIRECT_LIGHT,
    decl = DIRECT_LIGHT_PASS,
    execute = frame_graph_direct_light_execute,
    instance_group = .LIGHTING_CAMERAS,
  },
  .PARTICLES_RENDER = {
    id = .PARTICLES_RENDER,
    decl = PARTICLES_RENDER_PASS,
    execute = frame_graph_particles_render_execute,
    instance_group = .PARTICLES_CAMERAS,
  },
  .TRANSPARENT_RENDER = {
    id = .TRANSPARENT_RENDER,
    decl = TRANSPARENT_RENDER_PASS,
    execute = frame_graph_transparent_execute,
    instance_group = .TRANSPARENCY_CAMERAS,
  },
  .WIREFRAME_RENDER = {
    id = .WIREFRAME_RENDER,
    decl = WIREFRAME_RENDER_PASS,
    execute = frame_graph_wireframe_execute,
    instance_group = .TRANSPARENCY_CAMERAS,
  },
  .RANDOM_COLOR_RENDER = {
    id = .RANDOM_COLOR_RENDER,
    decl = RANDOM_COLOR_RENDER_PASS,
    execute = frame_graph_random_color_execute,
    instance_group = .TRANSPARENCY_CAMERAS,
  },
  .LINE_STRIP_RENDER = {
    id = .LINE_STRIP_RENDER,
    decl = LINE_STRIP_RENDER_PASS,
    execute = frame_graph_line_strip_execute,
    instance_group = .TRANSPARENCY_CAMERAS,
  },
  .SPRITE_RENDER = {
    id = .SPRITE_RENDER,
    decl = SPRITE_RENDER_PASS,
    execute = frame_graph_sprite_execute,
    instance_group = .TRANSPARENCY_CAMERAS,
  },
  .DEBUG = {
    id = .DEBUG,
    decl = DEBUG_PASS,
    execute = frame_graph_debug_execute,
    instance_group = .DEBUG_CAMERAS,
  },
  .POST_PROCESS = {
    id = .POST_PROCESS,
    decl = POST_PROCESS_PASS,
    execute = frame_graph_post_process_execute,
    instance_group = .ALWAYS,
  },
  .UI = {
    id = .UI,
    decl = UI_PASS,
    execute = frame_graph_ui_execute,
    instance_group = .ALWAYS,
  },
}

@(private)
frame_graph_manager :: proc(pass_ctx: ^rg.PassContext) -> ^Manager {
  when ODIN_DEBUG {
    assert(pass_ctx != nil, "PassContext must not be nil")
    assert(pass_ctx.exec_ctx != nil, "PassContext.exec_ctx must not be nil")
    assert(
      pass_ctx.exec_ctx.render_manager != nil,
      "GraphExecutionContext.render_manager must not be nil",
    )
  }
  return cast(^Manager)pass_ctx.exec_ctx.render_manager
}

@(private)
frame_graph_payload :: proc(pass_ctx: ^rg.PassContext) -> ^FrameGraphExecutionPayload {
  when ODIN_DEBUG {
    assert(pass_ctx != nil, "PassContext must not be nil")
    assert(pass_ctx.exec_ctx != nil, "PassContext.exec_ctx must not be nil")
    assert(pass_ctx.exec_ctx.frame_payload != nil, "GraphExecutionContext.frame_payload must not be nil")
  }
  return cast(^FrameGraphExecutionPayload)pass_ctx.exec_ctx.frame_payload
}

FrameGraphCommonBindings :: struct {
  camera_descriptor_set:          vk.DescriptorSet,
  bone_descriptor_set:            vk.DescriptorSet,
  textures_descriptor_set:        vk.DescriptorSet,
  material_descriptor_set:        vk.DescriptorSet,
  node_data_descriptor_set:       vk.DescriptorSet,
  mesh_data_descriptor_set:       vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer:                  vk.Buffer,
  index_buffer:                   vk.Buffer,
}

@(private)
frame_graph_common_bindings :: proc(
  manager: ^Manager,
  frame_index: u32,
) -> FrameGraphCommonBindings {
  return FrameGraphCommonBindings{
    camera_descriptor_set = manager.resource_pool.camera_buffer.descriptor_sets[frame_index],
    bone_descriptor_set = manager.resource_pool.bone_buffer.descriptor_sets[frame_index],
    textures_descriptor_set = manager.texture_manager.descriptor_set,
    material_descriptor_set = manager.resource_pool.material_buffer.descriptor_set,
    node_data_descriptor_set = manager.resource_pool.node_data_buffer.descriptor_set,
    mesh_data_descriptor_set = manager.resource_pool.mesh_data_buffer.descriptor_set,
    vertex_skinning_descriptor_set = manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
    vertex_buffer = manager.mesh_manager.vertex_buffer.buffer,
    index_buffer = manager.mesh_manager.index_buffer.buffer,
  }
}

frame_graph_shadow_compute_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  shadow.shadow_compute_execute(&manager.shadow, pass_ctx)
}

frame_graph_shadow_depth_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := shadow.shadow_depth_pass_deps_from_context(pass_ctx)
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.bone_descriptor_set = bindings.bone_descriptor_set
  deps.material_descriptor_set = bindings.material_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.mesh_data_descriptor_set = bindings.mesh_data_descriptor_set
  deps.vertex_skinning_descriptor_set = bindings.vertex_skinning_descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  shadow.shadow_depth_execute(&manager.shadow, pass_ctx, deps)
}

frame_graph_particle_simulation_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  deps := particles_compute.particle_simulation_pass_deps_from_context(
    pass_ctx,
  )
  particles_compute.particle_simulation_execute(
    &manager.particles_compute,
    pass_ctx,
    deps,
  )
}

frame_graph_visibility_culling_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  deps := occlusion_culling.visibility_culling_pass_deps_from_context(pass_ctx)
  cam_idx := pass_ctx.scope_index
  if cam, ok := manager.cameras[cam_idx]; ok {
    deps.enable_culling = cam.enable_culling
  }
  if cam_idx < rg.MAX_CAMERAS {
    deps.cull_input_descriptor_set =
      manager.resource_pool.camera_cull_input_descriptor_sets[cam_idx][
        pass_ctx.frame_index
      ]
    deps.cull_output_descriptor_set =
      manager.resource_pool.camera_cull_output_descriptor_sets[cam_idx][
        pass_ctx.frame_index
      ]
    prev_frame := alg.prev(pass_ctx.frame_index, rd.FRAMES_IN_FLIGHT)
    pyramid := manager.resource_pool.camera_depth_pyramids[cam_idx][prev_frame]
    deps.pyramid_width = pyramid.width
    deps.pyramid_height = pyramid.height
  }
  occlusion_culling.visibility_culling_pass_execute(
    &manager.visibility,
    pass_ctx,
    deps,
  )
}

frame_graph_depth_prepass_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := occlusion_culling.depth_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.bone_descriptor_set = bindings.bone_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.mesh_data_descriptor_set = bindings.mesh_data_descriptor_set
  deps.vertex_skinning_descriptor_set = bindings.vertex_skinning_descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  occlusion_culling.depth_pass_execute(&manager.visibility, pass_ctx, deps)
}

frame_graph_depth_pyramid_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  deps := occlusion_culling.depth_pyramid_pass_deps_from_context(pass_ctx)
  cam_idx := pass_ctx.scope_index
  if cam, ok := manager.cameras[cam_idx]; ok {
    deps.enable_depth_pyramid = cam.enable_depth_pyramid
  }
  if cam_idx < rg.MAX_CAMERAS {
    pyramid := manager.resource_pool.camera_depth_pyramids[cam_idx][
      pass_ctx.frame_index
    ]
    deps.mip_levels = pyramid.mip_levels
    for mip in 0 ..< pyramid.mip_levels {
      deps.depth_reduce_descriptor_sets[mip] =
        manager.resource_pool.camera_depth_reduce_descriptor_sets[cam_idx][
          pass_ctx.frame_index
        ][mip]
    }
  }
  occlusion_culling.depth_pyramid_pass_execute(
    &manager.visibility,
    pass_ctx,
    deps,
  )
}

frame_graph_geometry_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := geometry.geometry_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.bone_descriptor_set = bindings.bone_descriptor_set
  deps.material_descriptor_set = bindings.material_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.mesh_data_descriptor_set = bindings.mesh_data_descriptor_set
  deps.vertex_skinning_descriptor_set = bindings.vertex_skinning_descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  geometry.geometry_pass_execute(&manager.geometry, pass_ctx, deps)
}

frame_graph_ambient_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := ambient.ambient_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  ambient.ambient_pass_execute(&manager.ambient, pass_ctx, deps)
}

frame_graph_direct_light_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  payload := frame_graph_payload(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := direct_light.direct_light_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.lights_descriptor_set = manager.resource_pool.lights_buffer.descriptor_set
  deps.shadow_data_descriptor_set =
    manager.shadow.shadow_data_buffer.descriptor_sets[pass_ctx.frame_index]

  active_lights := make(
    [dynamic]direct_light.ActiveLightRuntime,
    0,
    len(payload.active_lights),
    context.temp_allocator,
  )
  for handle in payload.active_lights {
    light := gpu.get(&manager.resource_pool.lights_buffer.buffer, handle.index)
    append(
      &active_lights,
      direct_light.ActiveLightRuntime{
        index = handle.index,
        light_type = light.type,
        shadow_map_index = payload.shadow_texture_indices[handle.index],
      },
    )
  }
  deps.active_lights = active_lights[:]
  direct_light.direct_light_pass_execute(&manager.direct_light, pass_ctx, deps)
}

frame_graph_particles_render_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := particles_render.particles_render_pass_deps_from_context(pass_ctx)
  deps.camera_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  particles_render.particles_render_execute(
    &manager.particles_render,
    pass_ctx,
    deps,
  )
}

frame_graph_transparent_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := transparent.transparent_render_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.bone_descriptor_set = bindings.bone_descriptor_set
  deps.material_descriptor_set = bindings.material_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.mesh_data_descriptor_set = bindings.mesh_data_descriptor_set
  deps.vertex_skinning_descriptor_set = bindings.vertex_skinning_descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  transparent.transparent_render_pass_execute(
    &manager.transparent_renderer,
    pass_ctx,
    deps,
  )
}

frame_graph_wireframe_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := wireframe.wireframe_render_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.bone_descriptor_set = bindings.bone_descriptor_set
  deps.material_descriptor_set = bindings.material_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.mesh_data_descriptor_set = bindings.mesh_data_descriptor_set
  deps.vertex_skinning_descriptor_set = bindings.vertex_skinning_descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  wireframe.wireframe_render_pass_execute(
    &manager.wireframe_renderer,
    pass_ctx,
    deps,
  )
}

frame_graph_random_color_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := random_color.random_color_render_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.bone_descriptor_set = bindings.bone_descriptor_set
  deps.material_descriptor_set = bindings.material_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.mesh_data_descriptor_set = bindings.mesh_data_descriptor_set
  deps.vertex_skinning_descriptor_set = bindings.vertex_skinning_descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  random_color.random_color_render_pass_execute(
    &manager.random_color_renderer,
    pass_ctx,
    deps,
  )
}

frame_graph_line_strip_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := line_strip.line_strip_render_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.bone_descriptor_set = bindings.bone_descriptor_set
  deps.material_descriptor_set = bindings.material_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.mesh_data_descriptor_set = bindings.mesh_data_descriptor_set
  deps.vertex_skinning_descriptor_set = bindings.vertex_skinning_descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  line_strip.line_strip_render_pass_execute(
    &manager.line_strip_renderer,
    pass_ctx,
    deps,
  )
}

frame_graph_sprite_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  bindings := frame_graph_common_bindings(manager, pass_ctx.frame_index)
  deps := sprite.sprite_render_pass_deps_from_context(pass_ctx)
  deps.cameras_descriptor_set = bindings.camera_descriptor_set
  deps.textures_descriptor_set = bindings.textures_descriptor_set
  deps.node_data_descriptor_set = bindings.node_data_descriptor_set
  deps.sprite_descriptor_set = manager.resource_pool.sprite_buffer.descriptor_set
  deps.vertex_buffer = bindings.vertex_buffer
  deps.index_buffer = bindings.index_buffer
  sprite.sprite_render_pass_execute(&manager.sprite_renderer, pass_ctx, deps)
}

frame_graph_debug_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  deps := debug_pass_deps_from_context(pass_ctx)
  debug_pass_execute(manager, pass_ctx, deps)
}

frame_graph_post_process_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  payload := frame_graph_payload(pass_ctx)
  deps := post_process.post_process_pass_deps_from_context(
    pass_ctx,
    payload.main_camera_index,
  )
  deps.swapchain_view = payload.swapchain_view
  deps.swapchain_extent = payload.swapchain_extent
  deps.textures_descriptor_set = manager.texture_manager.descriptor_set
  post_process.post_process_pass_execute(&manager.post_process, pass_ctx, deps)
}

frame_graph_ui_execute :: proc(pass_ctx: ^rg.PassContext) {
  manager := frame_graph_manager(pass_ctx)
  payload := frame_graph_payload(pass_ctx)
  deps := ui_render.ui_pass_deps_from_context(pass_ctx)
  deps.textures_descriptor_set = manager.texture_manager.descriptor_set
  deps.ui_vertex_buffer = manager.resource_pool.ui_resources.vertex_buffers[pass_ctx.frame_index]
  deps.ui_index_buffer = manager.resource_pool.ui_resources.index_buffers[pass_ctx.frame_index]
  deps.commands = payload.ui_commands
  deps.swapchain_view = payload.swapchain_view
  deps.swapchain_extent = payload.swapchain_extent
  ui_render.ui_pass_execute(&manager.ui, pass_ctx, deps)
}

@(private)
frame_graph_instance_indices :: proc(
  input: ^FrameGraphTemplateBuildInput,
  group: FrameGraphInstanceGroup,
) -> (
  []u32,
  bool,
) {
  switch group {
  case .ALWAYS:
    return {}, true
  case .ACTIVE_LIGHTS:
    if len(input.active_light_slots) == 0 do return {}, false
    return input.active_light_slots, true
  case .CULLING_CAMERAS:
    if len(input.culling_cameras) == 0 do return {}, false
    return input.culling_cameras, true
  case .DEPTH_CAMERAS:
    if len(input.depth_cameras) == 0 do return {}, false
    return input.depth_cameras, true
  case .DEPTH_PYRAMID_CAMERAS:
    if len(input.depth_pyramid_cameras) == 0 do return {}, false
    return input.depth_pyramid_cameras, true
  case .GEOMETRY_CAMERAS:
    if len(input.geometry_cameras) == 0 do return {}, false
    return input.geometry_cameras, true
  case .LIGHTING_CAMERAS:
    if len(input.lighting_cameras) == 0 do return {}, false
    return input.lighting_cameras, true
  case .PARTICLES_CAMERAS:
    if len(input.particles_cameras) == 0 do return {}, false
    return input.particles_cameras, true
  case .TRANSPARENCY_CAMERAS:
    if len(input.transparency_cameras) == 0 do return {}, false
    return input.transparency_cameras, true
  case .DEBUG_CAMERAS:
    if len(input.debug_cameras) == 0 do return {}, false
    return input.debug_cameras, true
  }
  return {}, false
}

append_static_templates :: proc(
  templates: ^[dynamic]rg.PassTemplate,
  input: ^FrameGraphTemplateBuildInput,
) {
  for pass_id in FrameGraphPassId {
    entry := STATIC_TEMPLATES[pass_id]
    when ODIN_DEBUG {
      assert(
        u32(entry.decl.id) == u32(entry.id),
        "PassTemplate.id must match registry entry id",
      )
    }
    instance_indices, enabled := frame_graph_instance_indices(
      input,
      entry.instance_group,
    )
    if !enabled do continue

    decl := entry.decl
    if entry.id == .POST_PROCESS {
      decl.inputs = build_post_process_template_inputs(input.main_camera_index)
    }

    template := rg.graph_make_pass_template(
      decl,
      instance_indices,
      entry.execute,
    )
    template.id = rg.PassTemplateId(entry.id)
    append(templates, template)
  }
}

@(private)
build_post_process_template_inputs :: proc(
  main_camera_index: u32,
) -> []rg.ResourceRefTemplate {
  inputs := make([dynamic]rg.ResourceRefTemplate, 0, 9, context.temp_allocator)

  append(
    &inputs,
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_POSITION,
      instance = rg.FixedResourceTemplate {scope_index = main_camera_index},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_NORMAL,
      instance = rg.FixedResourceTemplate {scope_index = main_camera_index},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_ALBEDO,
      instance = rg.FixedResourceTemplate {scope_index = main_camera_index},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_METALLIC_ROUGHNESS,
      instance = rg.FixedResourceTemplate {scope_index = main_camera_index},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_EMISSIVE,
      instance = rg.FixedResourceTemplate {scope_index = main_camera_index},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.FixedResourceTemplate {scope_index = main_camera_index},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.FixedResourceTemplate {scope_index = main_camera_index},
    },
    rg.ResourceRefTemplate {
      index = .POST_PROCESS_IMAGE_0,
      instance = rg.FixedResourceTemplate {scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .POST_PROCESS_IMAGE_1,
      instance = rg.FixedResourceTemplate {scope_index = 1},
    },
  )

  return inputs[:]
}

collect_active_light_slots :: proc(manager: ^Manager) -> []u32 {
  active_light_slots := make([dynamic]u32, context.temp_allocator)
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    if manager.shadow.slot_active[slot] {
      append(&active_light_slots, u32(slot))
    }
  }
  return active_light_slots[:]
}

build_shadow_texture_indices :: proc(
  manager: ^Manager,
  active_lights: []rd.LightHandle,
  frame_index: u32,
) -> [rd.MAX_LIGHTS]u32 {
  shadow_texture_indices: [rd.MAX_LIGHTS]u32
  for i in 0 ..< rd.MAX_LIGHTS {
    shadow_texture_indices[i] = 0xFFFFFFFF
  }
  for handle in active_lights {
    light_data := gpu.get(
      &manager.resource_pool.lights_buffer.buffer,
      handle.index,
    )
    shadow_texture_indices[handle.index] = shadow.get_texture_index(
      &manager.shadow,
      light_data.type,
      light_data.shadow_index,
      frame_index,
    )
  }
  return shadow_texture_indices
}

build_frame_graph_template_input :: proc(
  manager: ^Manager,
  active_cameras: []u32,
  active_light_slots: []u32,
  main_camera_index: u32,
) -> FrameGraphTemplateBuildInput {
  depth_cameras := make([dynamic]u32, context.temp_allocator)
  culling_cameras := make([dynamic]u32, context.temp_allocator)
  depth_pyramid_cameras := make([dynamic]u32, context.temp_allocator)
  geometry_cameras := make([dynamic]u32, context.temp_allocator)
  lighting_cameras := make([dynamic]u32, context.temp_allocator)
  particles_cameras := make([dynamic]u32, context.temp_allocator)
  transparency_cameras := make([dynamic]u32, context.temp_allocator)
  debug_cameras := make([dynamic]u32, context.temp_allocator)

  for cam_index in active_cameras {
    camera, camera_ok := manager.cameras[cam_index]
    if !camera_ok do continue

    append(&depth_cameras, cam_index)
    if camera.enable_culling {
      append(&culling_cameras, cam_index)
    }
    if camera.enable_depth_pyramid {
      append(&depth_pyramid_cameras, cam_index)
    }

    if .GEOMETRY in camera.enabled_passes ||
       .LIGHTING in camera.enabled_passes {
      append(&geometry_cameras, cam_index)
    }
    if .LIGHTING in camera.enabled_passes {
      append(&lighting_cameras, cam_index)
    }
    if .PARTICLES in camera.enabled_passes {
      append(&particles_cameras, cam_index)
    }
    if .TRANSPARENCY in camera.enabled_passes {
      append(&transparency_cameras, cam_index)
    }
  }

  if len(manager.debug_renderer.bone_instances) > 0 {
    append(&debug_cameras, main_camera_index)
  }

  return FrameGraphTemplateBuildInput {
    active_light_slots = active_light_slots,
    culling_cameras = culling_cameras[:],
    depth_cameras = depth_cameras[:],
    depth_pyramid_cameras = depth_pyramid_cameras[:],
    geometry_cameras = geometry_cameras[:],
    lighting_cameras = lighting_cameras[:],
    particles_cameras = particles_cameras[:],
    transparency_cameras = transparency_cameras[:],
    debug_cameras = debug_cameras[:],
    main_camera_index = main_camera_index,
  }
}

build_frame_graph_templates :: proc(
  input: ^FrameGraphTemplateBuildInput,
) -> []rg.PassTemplate {
  templates := make(
    [dynamic]rg.PassTemplate,
    0,
    len(FrameGraphPassId),
    context.temp_allocator,
  )
  append_static_templates(&templates, input)
  return templates[:]
}
