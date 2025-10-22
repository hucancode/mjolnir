package world

import "../animation"
import "../geometry"
import "../gpu"
import "../resources"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import path "core:path/filepath"
import "core:slice"
import "core:strings"
import "vendor:cgltf"
import vk "vendor:vulkan"

@(private = "file")
AssetManifest :: struct {
  unique_textures:  [dynamic]^cgltf.texture,
  unique_materials: [dynamic]^cgltf.material,
  meshes:           [dynamic]^cgltf.mesh,
  skins:            [dynamic]^cgltf.skin,
}

@(private = "file")
GeometryData :: struct {
  geometry:        geometry.Geometry,
  material_handle: resources.Handle,
}

@(private = "file")
SkinData :: struct {
  bones:                []resources.Bone,
  root_bone_idx:        u32,
  matrix_buffer_offset: u32,
}

load_gltf :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  path: string,
) -> (
  nodes: [dynamic]resources.Handle,
  ret: cgltf.result,
) {
  // step 0: cgltf
  gltf_path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
  options: cgltf.options
  gltf_data := cgltf.parse_file(options, gltf_path_cstr) or_return
  defer cgltf.free(gltf_data)
  if len(gltf_data.buffers) > 0 {
    cgltf.load_buffers(options, gltf_data, gltf_path_cstr) or_return
  }
  nodes = make([dynamic]resources.Handle, 0)
  if len(gltf_data.nodes) == 0 {
    return nodes, .success
  }
  // step 1: Asset Discovery
  manifest := discover_assets(gltf_data)
  defer {
    delete(manifest.unique_textures)
    delete(manifest.unique_materials)
    delete(manifest.meshes)
    delete(manifest.skins)
  }
  // step 2: Resource Loading
  texture_cache := make(
    map[^cgltf.texture]resources.Handle,
    context.temp_allocator,
  )
  material_cache := make(
    map[^cgltf.material]resources.Handle,
    context.temp_allocator,
  )
  load_textures_batch(
    world,
    rm,
    gctx,
    path,
    gltf_data,
    manifest.unique_textures[:],
    &texture_cache,
  ) or_return
  load_materials_batch(
    world,
    rm,
    gctx,
    path,
    gltf_data,
    manifest.unique_materials[:],
    &texture_cache,
    &material_cache,
  ) or_return
  // step 3: Geometry Processing
  geometry_cache := make(map[^cgltf.mesh]GeometryData, context.temp_allocator)
  mesh_skinning_map := make(map[^cgltf.mesh]bool, context.temp_allocator)
  for &node in gltf_data.nodes {
    if node.mesh != nil && node.skin != nil {
      mesh_skinning_map[node.mesh] = true
    }
  }
  process_geometries(
    world,
    rm,
    gctx,
    path,
    gltf_data,
    manifest.meshes[:],
    &texture_cache,
    &material_cache,
    &geometry_cache,
    mesh_skinning_map,
  ) or_return
  // step 4: Skinning Processing
  skin_cache := make(map[^cgltf.skin]SkinData, context.temp_allocator)
  process_skins(world, rm, gctx, gltf_data, manifest.skins[:], &skin_cache)
  // step 5: Scene Construction
  construct_scene(
    world,
    rm,
    gctx,
    gltf_data,
    &geometry_cache,
    &skin_cache,
    &nodes,
  ) or_return
  log.infof("GLTF loading complete:")
  log.infof("  - Unique textures: %d", len(texture_cache))
  log.infof("  - Unique materials: %d", len(material_cache))
  log.infof("  - Meshes: %d", len(geometry_cache))
  log.infof("  - Skins: %d", len(skin_cache))
  return nodes, .success
}

@(private = "file")
discover_assets :: proc(gltf_data: ^cgltf.data) -> AssetManifest {
  manifest: AssetManifest
  manifest.unique_textures = make([dynamic]^cgltf.texture, 0)
  manifest.unique_materials = make([dynamic]^cgltf.material, 0)
  manifest.meshes = make([dynamic]^cgltf.mesh, 0)
  manifest.skins = make([dynamic]^cgltf.skin, 0)
  texture_set := make(map[^cgltf.texture]bool, context.temp_allocator)
  material_set := make(map[^cgltf.material]bool, context.temp_allocator)
  mesh_set := make(map[^cgltf.mesh]bool, context.temp_allocator)
  skin_set := make(map[^cgltf.skin]bool, context.temp_allocator)
  for &node in gltf_data.nodes {
    if node.mesh != nil && node.mesh not_in mesh_set {
      append(&manifest.meshes, node.mesh)
      mesh_set[node.mesh] = true
      for &primitive in node.mesh.primitives {
        if primitive.material != nil &&
           primitive.material not_in material_set {
          append(&manifest.unique_materials, primitive.material)
          material_set[primitive.material] = true
          material := primitive.material
          if material.pbr_metallic_roughness.base_color_texture.texture !=
             nil {
            tex := material.pbr_metallic_roughness.base_color_texture.texture
            if tex not_in texture_set {
              append(&manifest.unique_textures, tex)
              texture_set[tex] = true
            }
          }
          if material.has_pbr_metallic_roughness &&
             material.pbr_metallic_roughness.metallic_roughness_texture.texture !=
               nil {
            tex :=
              material.pbr_metallic_roughness.metallic_roughness_texture.texture
            if tex not_in texture_set {
              append(&manifest.unique_textures, tex)
              texture_set[tex] = true
            }
          }
          if material.normal_texture.texture != nil {
            tex := material.normal_texture.texture
            if tex not_in texture_set {
              append(&manifest.unique_textures, tex)
              texture_set[tex] = true
            }
          }
          if material.emissive_texture.texture != nil {
            tex := material.emissive_texture.texture
            if tex not_in texture_set {
              append(&manifest.unique_textures, tex)
              texture_set[tex] = true
            }
          }
        }
      }
    }
    if node.skin != nil && node.skin not_in skin_set {
      append(&manifest.skins, node.skin)
      skin_set[node.skin] = true
    }
  }
  log.infof("Asset Discovery Complete:")
  log.infof("  - Unique textures: %d", len(manifest.unique_textures))
  log.infof("  - Unique materials: %d", len(manifest.unique_materials))
  log.infof("  - Meshes: %d", len(manifest.meshes))
  log.infof("  - Skins: %d", len(manifest.skins))
  return manifest
}

@(private = "file")
load_textures_batch :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  gltf_path: string,
  gltf_data: ^cgltf.data,
  textures: []^cgltf.texture,
  texture_cache: ^map[^cgltf.texture]resources.Handle,
) -> cgltf.result {
  for gltf_texture in textures {
    if gltf_texture == nil || gltf_texture.image_ == nil {
      continue
    }
    gltf_image := gltf_texture.image_
    pixel_data: []u8
    if gltf_image.uri != nil {
      texture_path_str := path.join(
        {path.dir(gltf_path), string(gltf_image.uri)},
      )
      ok: bool
      pixel_data, ok = os.read_entire_file(texture_path_str)
      if !ok {
        log.errorf("Failed to read texture file '%s'", texture_path_str)
        return .file_not_found
      }
    } else if gltf_image.buffer_view != nil {
      view := gltf_image.buffer_view
      buffer := view.buffer
      src_data_ptr := mem.ptr_offset(cast(^u8)buffer.data, view.offset)
      pixel_data = slice.from_ptr(src_data_ptr, int(view.size))
      pixel_data = slice.clone(pixel_data)
    } else {
      continue
    }
    tex_handle, _, texture_result := resources.create_texture(
      gctx,
      rm,
      pixel_data,
    )
    if texture_result != .SUCCESS {
      return .io_error
    }
    delete(pixel_data)
    texture_cache[gltf_texture] = tex_handle
    log.infof("Created texture %v", tex_handle)
  }
  return .success
}

@(private = "file")
load_materials_batch :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  gltf_path: string,
  gltf_data: ^cgltf.data,
  materials: []^cgltf.material,
  texture_cache: ^map[^cgltf.texture]resources.Handle,
  material_cache: ^map[^cgltf.material]resources.Handle,
) -> cgltf.result {
  for gltf_material in materials {
    if gltf_material == nil do continue
    albedo, metallic_roughness, normal, emissive, occlusion, features :=
      load_material_textures(gltf_material, texture_cache)
    material_handle, _, material_result := resources.create_material(
      rm,
      features,
      .PBR,
      albedo,
      metallic_roughness,
      normal,
      emissive,
      occlusion,
    )
    if material_result != .SUCCESS do return .invalid_gltf
    material_cache[gltf_material] = material_handle
    log.infof("Created material %v", material_handle)
  }
  return .success
}

@(private = "file")
load_material_textures :: proc(
  gltf_material: ^cgltf.material,
  texture_cache: ^map[^cgltf.texture]resources.Handle,
) -> (
  albedo: resources.Handle,
  metallic_roughness: resources.Handle,
  normal: resources.Handle,
  emissive: resources.Handle,
  occlusion: resources.Handle,
  features: resources.ShaderFeatureSet,
) {
  if gltf_material.has_pbr_metallic_roughness &&
     gltf_material.pbr_metallic_roughness.metallic_roughness_texture.texture !=
       nil {
    if handle, found :=
         texture_cache[gltf_material.pbr_metallic_roughness.metallic_roughness_texture.texture];
       found {
      metallic_roughness = handle
      features |= {.METALLIC_ROUGHNESS_TEXTURE}
    }
  }
  if gltf_material.pbr_metallic_roughness.base_color_texture.texture != nil {
    if handle, found :=
         texture_cache[gltf_material.pbr_metallic_roughness.base_color_texture.texture];
       found {
      albedo = handle
      features |= {.ALBEDO_TEXTURE}
    }
  }
  if gltf_material.normal_texture.texture != nil {
    if handle, found := texture_cache[gltf_material.normal_texture.texture];
       found {
      normal = handle
      features |= {.NORMAL_TEXTURE}
    }
  }
  if gltf_material.emissive_texture.texture != nil {
    if handle, found := texture_cache[gltf_material.emissive_texture.texture];
       found {
      emissive = handle
      features |= {.EMISSIVE_TEXTURE}
    }
  }
  if gltf_material.occlusion_texture.texture != nil {
    if handle, found := texture_cache[gltf_material.occlusion_texture.texture];
       found {
      occlusion = handle
      features |= {.OCCLUSION_TEXTURE}
    }
  }
  return
}

@(private = "file")
process_geometries :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  gltf_path: string,
  gltf_data: ^cgltf.data,
  meshes: []^cgltf.mesh,
  texture_cache: ^map[^cgltf.texture]resources.Handle,
  material_cache: ^map[^cgltf.material]resources.Handle,
  geometry_cache: ^map[^cgltf.mesh]GeometryData,
  mesh_skinning_map: map[^cgltf.mesh]bool,
) -> cgltf.result {
  for mesh in meshes {
    is_skinned := mesh in mesh_skinning_map
    geometry_data := process_mesh_primitives(
      mesh,
      material_cache,
      is_skinned,
    ) or_return
    geometry_cache[mesh] = geometry_data
    log.infof(
      "Processed mesh with %d vertices, %d indices",
      len(geometry_data.geometry.vertices),
      len(geometry_data.geometry.indices),
    )
  }
  return .success
}

@(private = "file")
process_mesh_primitives :: proc(
  mesh: ^cgltf.mesh,
  material_cache: ^map[^cgltf.material]resources.Handle,
  include_skinning: bool,
) -> (
  GeometryData,
  cgltf.result,
) {
  primitives := mesh.primitives
  if len(primitives) == 0 {
    return {}, .invalid_gltf
  }
  material_handle: resources.Handle
  if primitives[0].material != nil {
    if handle, found := material_cache[primitives[0].material]; found {
      material_handle = handle
    }
  }
  combined_vertices := make(
    [dynamic]geometry.Vertex,
    0,
    context.temp_allocator,
  )
  combined_indices := make([dynamic]u32, 0, context.temp_allocator)
  combined_skinnings: [dynamic]geometry.SkinningData
  if include_skinning {
    combined_skinnings = make(
      [dynamic]geometry.SkinningData,
      0,
      context.temp_allocator,
    )
  }
  for &prim in primitives {
    vertex_offset := u32(len(combined_vertices))
    vertices_num := prim.attributes[0].data.count
    vertices := make([]geometry.Vertex, vertices_num, context.temp_allocator)
    skinnings: []geometry.SkinningData
    if include_skinning {
      skinnings = make(
        []geometry.SkinningData,
        vertices_num,
        context.temp_allocator,
      )
    }
    process_vertex_attributes(&prim, vertices, skinnings)
    append(&combined_vertices, ..vertices[:])
    if include_skinning {
      append(&combined_skinnings, ..skinnings[:])
    }
    if prim.indices != nil {
      indices := make([]u32, prim.indices.count, context.temp_allocator)
      _ = cgltf.accessor_unpack_indices(
        prim.indices,
        raw_data(indices),
        size_of(u32),
        prim.indices.count,
      )
      for &index in indices {
        index += vertex_offset
      }
      append(&combined_indices, ..indices[:])
    }
  }
  final_vertices := slice.clone(combined_vertices[:])
  final_indices := slice.clone(combined_indices[:])
  geometry_data: geometry.Geometry
  if include_skinning {
    final_skinnings := slice.clone(combined_skinnings[:])
    geometry_data = geometry.make_geometry(
      final_vertices,
      final_indices,
      final_skinnings,
    )
  } else {
    geometry_data = geometry.make_geometry(final_vertices, final_indices)
  }
  return GeometryData {
      geometry = geometry_data,
      material_handle = material_handle,
    },
    .success
}

@(private = "file")
process_vertex_attributes :: proc(
  primitive: ^cgltf.primitive,
  vertices: []geometry.Vertex,
  skinnings: []geometry.SkinningData = nil,
) {
  for attribute in primitive.attributes {
    accessor := attribute.data
    #partial switch attribute.type {
    case .position:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        cgltf.accessor_read_float(
          accessor,
          uint(i),
          raw_data(vertices[i].position[:]),
          3,
        ) or_continue
      }
    case .normal:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        cgltf.accessor_read_float(
          accessor,
          uint(i),
          raw_data(vertices[i].normal[:]),
          3,
        ) or_continue
      }
    case .texcoord:
      if attribute.index == 0 {
        for i in 0 ..< min(int(accessor.count), len(vertices)) {
          cgltf.accessor_read_float(
            accessor,
            uint(i),
            raw_data(vertices[i].uv[:]),
            2,
          ) or_continue
        }
      }
    case .tangent:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        cgltf.accessor_read_float(
          accessor,
          uint(i),
          raw_data(vertices[i].tangent[:]),
          4,
        ) or_continue
      }
    case .joints:
      if attribute.index == 0 && skinnings != nil {
        for i in 0 ..< min(int(accessor.count), len(skinnings)) {
          cgltf.accessor_read_uint(
            accessor,
            uint(i),
            raw_data(skinnings[i].joints[:]),
            len(skinnings[i].joints),
          ) or_continue
        }
      }
    case .weights:
      if attribute.index == 0 && skinnings != nil {
        for i in 0 ..< min(int(accessor.count), len(skinnings)) {
          cgltf.accessor_read_float(
            accessor,
            uint(i),
            raw_data(skinnings[i].weights[:]),
            4,
          ) or_continue
        }
      }
    }
  }
}

@(private = "file")
process_skins :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  gltf_data: ^cgltf.data,
  skins: []^cgltf.skin,
  skin_cache: ^map[^cgltf.skin]SkinData,
) {
  for gltf_skin in skins {
    bones := make([]resources.Bone, len(gltf_skin.joints))
    for joint_node, i in gltf_skin.joints {
      bones[i].name = string(joint_node.name)
      if gltf_skin.inverse_bind_matrices != nil {
        ibm_floats: [16]f32
        read := cgltf.accessor_read_float(
          gltf_skin.inverse_bind_matrices,
          uint(i),
          raw_data(ibm_floats[:]),
          16,
        )
        if read {
          bones[i].inverse_bind_matrix = geometry.matrix_from_arr(ibm_floats)
          continue
        }
      }
      bones[i].inverse_bind_matrix = linalg.MATRIX4F32_IDENTITY
    }
    for joint_node, i in gltf_skin.joints {
      bones[i].children = make([]u32, len(joint_node.children))
      for child, j in joint_node.children {
        if idx, found := slice.linear_search(gltf_skin.joints, child); found {
          bones[i].children[j] = u32(idx)
        }
      }
    }
    child_bone_indices := make([dynamic]u32, 0, context.temp_allocator)
    for bone in bones {
      append(&child_bone_indices, ..bone.children[:])
    }
    root_bone_idx: u32 = 0
    for i in 0 ..< len(bones) {
      if !slice.contains(child_bone_indices[:], u32(i)) {
        root_bone_idx = u32(i)
        break
      }
    }
    matrix_buffer_offset := resources.slab_alloc(
      &rm.bone_matrix_slab,
      u32(len(bones)),
    )
    l := matrix_buffer_offset
    r := l + u32(len(bones))
    bone_matrices := gpu.mutable_buffer_get_all(&rm.bone_buffer)[l:r]
    slice.fill(bone_matrices, linalg.MATRIX4F32_IDENTITY)
    skin_cache[gltf_skin] = SkinData {
      bones                = bones,
      root_bone_idx        = root_bone_idx,
      matrix_buffer_offset = matrix_buffer_offset,
    }
    log.infof(
      "Processed skin with %d bones, root bone %d",
      len(bones),
      root_bone_idx,
    )
  }
}

@(private = "file")
construct_scene :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  gltf_data: ^cgltf.data,
  geometry_cache: ^map[^cgltf.mesh]GeometryData,
  skin_cache: ^map[^cgltf.skin]SkinData,
  nodes: ^[dynamic]resources.Handle,
) -> cgltf.result {
  TraverseEntry :: struct {
    idx:    u32,
    parent: resources.Handle,
  }
  stack := make([dynamic]TraverseEntry, 0, context.temp_allocator)
  child_node_indices := make([dynamic]u32, 0, context.temp_allocator)
  node_ptr_to_idx_map := make(map[^cgltf.node]u32, context.temp_allocator)
  skin_to_first_mesh := make(
    map[^cgltf.skin]resources.Handle,
    context.temp_allocator,
  )
  for &node, i in gltf_data.nodes {
    node_ptr_to_idx_map[&node] = u32(i)
  }
  for &node in gltf_data.nodes {
    for child_ptr in node.children {
      child_idx := node_ptr_to_idx_map[child_ptr]
      append(&child_node_indices, child_idx)
    }
  }
  for i in 0 ..< len(gltf_data.nodes) {
    if !slice.contains(child_node_indices[:], u32(i)) {
      append(&stack, TraverseEntry{idx = u32(i), parent = world.root})
    }
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    gltf_node := &gltf_data.nodes[entry.idx]
    node_handle, node, ok := resources.alloc(&world.nodes)
    if !ok do continue
    init_node(node, string(gltf_node.name))
    node.transform = geometry.TRANSFORM_IDENTITY
    if gltf_node.has_matrix {
      node.transform = geometry.decompose_matrix(
        geometry.matrix_from_arr(gltf_node.matrix_),
      )
    } else {
      if gltf_node.has_translation {
        node.transform.position = gltf_node.translation
      }
      if gltf_node.has_rotation {
        node.transform.rotation = quaternion(
          x = gltf_node.rotation[0],
          y = gltf_node.rotation[1],
          z = gltf_node.rotation[2],
          w = gltf_node.rotation[3],
        )
      }
      if gltf_node.has_scale {
        node.transform.scale = gltf_node.scale
      }
      node.transform.is_dirty = true
    }
    node.parent = entry.parent
    if gltf_node.mesh != nil {
      if geometry_data, found := geometry_cache[gltf_node.mesh]; found {
        if gltf_node.skin != nil {
          if skin_data, skin_found := skin_cache[gltf_node.skin]; skin_found {
            mesh_handle, mesh, mesh_ok := resources.alloc(&rm.meshes)
            if !mesh_ok {
              log.error("Failed to allocate mesh for skinned mesh")
              continue
            }
            init_result := resources.mesh_init(
              mesh,
              gctx,
              rm,
              geometry_data.geometry,
            )
            if init_result != vk.Result.SUCCESS {
              log.error("Failed to initialize skinned mesh")
              resources.mesh_destroy(mesh, gctx, rm)
              resources.free(&rm.meshes, mesh_handle)
              continue
            }
            skinning, _ := &mesh.skinning.?
            // Deep clone bones including their children slices
            skinning.bones = make([]resources.Bone, len(skin_data.bones))
            for src_bone, i in skin_data.bones {
              skinning.bones[i] = src_bone
              skinning.bones[i].children = slice.clone(src_bone.children)
              skinning.bones[i].name = strings.clone(src_bone.name)
            }
            skinning.root_bone_index = skin_data.root_bone_idx
            gpu_result := resources.mesh_write_to_gpu(rm, mesh_handle, mesh)
            if gpu_result != vk.Result.SUCCESS {
              log.error("Failed to write skinned mesh data to GPU")
              resources.mesh_destroy(mesh, gctx, rm)
              resources.free(&rm.meshes, mesh_handle)
              continue
            }
            node.attachment = MeshAttachment {
              handle = mesh_handle,
              material = geometry_data.material_handle,
              cast_shadow = true,
              skinning = NodeSkinning {
                bone_matrix_buffer_offset = skin_data.matrix_buffer_offset,
              },
            }
            if _, has_first_mesh := skin_to_first_mesh[gltf_node.skin];
               !has_first_mesh {
              skin_to_first_mesh[gltf_node.skin] = mesh_handle
              load_animations(
                world,
                rm,
                gctx,
                gltf_data,
                gltf_node.skin,
                mesh_handle,
              )
            }
          }
        } else {
          mesh_handle, _, ret := resources.create_mesh(
            gctx,
            rm,
            geometry_data.geometry,
          )
          if ret == .SUCCESS {
            node.attachment = MeshAttachment {
              handle      = mesh_handle,
              material    = geometry_data.material_handle,
              cast_shadow = true,
            }
          }
        }
      }
    }
    attach(world.nodes, entry.parent, node_handle)
    if entry.parent == world.root {
      append(nodes, node_handle)
    }
    for child_ptr in gltf_node.children {
      if child_idx, found := node_ptr_to_idx_map[child_ptr]; found {
        append(&stack, TraverseEntry{idx = child_idx, parent = node_handle})
      }
    }
  }
  return .success
}

@(private = "file")
load_animations :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  gltf_data: ^cgltf.data,
  gltf_skin: ^cgltf.skin,
  mesh_handle: resources.Handle,
) -> bool {
  mesh := resources.get(rm.meshes, mesh_handle)
  if mesh == nil do return false
  skinning := &mesh.skinning.?
  for gltf_anim, i in gltf_data.animations {
    _, clip, clip_ok := resources.alloc(&rm.animation_clips)
    if !clip_ok {
      log.error("Failed to allocate animation clip")
      continue
    }
    if gltf_anim.name != nil {
      clip.name = strings.clone_from_cstring(gltf_anim.name)
    } else {
      clip.name = fmt.tprintf("animation_%d", i)
    }
    clip.channels = make([]animation.Channel, len(skinning.bones))
    for gltf_channel in gltf_anim.channels {
      if gltf_channel.target_node == nil || gltf_channel.sampler == nil {
        continue
      }
      n := gltf_channel.sampler.input.count
      bone_idx := slice.linear_search(
        gltf_skin.joints,
        gltf_channel.target_node,
      ) or_continue
      engine_channel := &clip.channels[bone_idx]
      interpolation_mode := animation.InterpolationMode.LINEAR
      #partial switch gltf_channel.sampler.interpolation {
      case .step:
        interpolation_mode = .STEP
      case .linear:
        interpolation_mode = .LINEAR
      case .cubic_spline:
        interpolation_mode = .CUBICSPLINE
      }
      #partial switch gltf_channel.target_path {
      case .translation:
        engine_channel.position_interpolation = interpolation_mode
        if interpolation_mode == .CUBICSPLINE {
          engine_channel.cubic_positions = make(
            type_of(engine_channel.cubic_positions),
            n,
          )
          for i in 0 ..< int(n) {
            time_val: [1]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.input,
              uint(i),
              raw_data(time_val[:]),
              1,
            ) or_continue
            clip.duration = max(clip.duration, time_val[0])
            in_tangent: [3]f32
            value: [3]f32
            out_tangent: [3]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 0),
              raw_data(in_tangent[:]),
              3,
            ) or_continue
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 1),
              raw_data(value[:]),
              3,
            ) or_continue
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 2),
              raw_data(out_tangent[:]),
              3,
            ) or_continue
            engine_channel.cubic_positions[i] = {
              time        = time_val[0],
              in_tangent  = in_tangent,
              value       = value,
              out_tangent = out_tangent,
            }
          }
        } else {
          engine_channel.positions = make(type_of(engine_channel.positions), n)
          for i in 0 ..< int(n) {
            time_val: [1]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.input,
              uint(i),
              raw_data(time_val[:]),
              1,
            ) or_continue
            clip.duration = max(clip.duration, time_val[0])
            position: [3]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i),
              raw_data(position[:]),
              3,
            ) or_continue
            engine_channel.positions[i] = {
              time  = time_val[0],
              value = position,
            }
          }
        }
      case .rotation:
        engine_channel.rotation_interpolation = interpolation_mode
        if interpolation_mode == .CUBICSPLINE {
          engine_channel.cubic_rotations = make(
            type_of(engine_channel.cubic_rotations),
            n,
          )
          for i in 0 ..< int(n) {
            time_val: [1]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.input,
              uint(i),
              raw_data(time_val[:]),
              1,
            ) or_continue
            clip.duration = max(clip.duration, time_val[0])
            in_tangent: [4]f32
            value: [4]f32
            out_tangent: [4]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 0),
              raw_data(in_tangent[:]),
              4,
            ) or_continue
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 1),
              raw_data(value[:]),
              4,
            ) or_continue
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 2),
              raw_data(out_tangent[:]),
              4,
            ) or_continue
            engine_channel.cubic_rotations[i] = {
              time        = time_val[0],
              in_tangent  = quaternion(
                x = in_tangent[0],
                y = in_tangent[1],
                z = in_tangent[2],
                w = in_tangent[3],
              ),
              value       = quaternion(
                x = value[0],
                y = value[1],
                z = value[2],
                w = value[3],
              ),
              out_tangent = quaternion(
                x = out_tangent[0],
                y = out_tangent[1],
                z = out_tangent[2],
                w = out_tangent[3],
              ),
            }
          }
        } else {
          engine_channel.rotations = make(type_of(engine_channel.rotations), n)
          for i in 0 ..< int(n) {
            time_val: [1]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.input,
              uint(i),
              raw_data(time_val[:]),
              1,
            ) or_continue
            clip.duration = max(clip.duration, time_val[0])
            rotation: [4]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i),
              raw_data(rotation[:]),
              4,
            ) or_continue
            engine_channel.rotations[i] = {
              time  = time_val[0],
              value = quaternion(
                x = rotation[0],
                y = rotation[1],
                z = rotation[2],
                w = rotation[3],
              ),
            }
          }
        }
      case .scale:
        engine_channel.scale_interpolation = interpolation_mode
        if interpolation_mode == .CUBICSPLINE {
          engine_channel.cubic_scales = make(
            type_of(engine_channel.cubic_scales),
            n,
          )
          for i in 0 ..< int(n) {
            time_val: [1]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.input,
              uint(i),
              raw_data(time_val[:]),
              1,
            ) or_continue
            clip.duration = max(clip.duration, time_val[0])
            in_tangent: [3]f32
            value: [3]f32
            out_tangent: [3]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 0),
              raw_data(in_tangent[:]),
              3,
            ) or_continue
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 1),
              raw_data(value[:]),
              3,
            ) or_continue
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i * 3 + 2),
              raw_data(out_tangent[:]),
              3,
            ) or_continue
            engine_channel.cubic_scales[i] = {
              time        = time_val[0],
              in_tangent  = in_tangent,
              value       = value,
              out_tangent = out_tangent,
            }
          }
        } else {
          engine_channel.scales = make(type_of(engine_channel.scales), n)
          for i in 0 ..< int(n) {
            time_val: [1]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.input,
              uint(i),
              raw_data(time_val[:]),
              1,
            ) or_continue
            clip.duration = max(clip.duration, time_val[0])
            scale: [3]f32
            cgltf.accessor_read_float(
              gltf_channel.sampler.output,
              uint(i),
              raw_data(scale[:]),
              3,
            ) or_continue
            engine_channel.scales[i] = {
              time  = time_val[0],
              value = scale,
            }
          }
        }
      }
    }
  }
  return true
}
