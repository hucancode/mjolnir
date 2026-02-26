package world

import anim "../animation"
import cont "../containers"
import "../geometry"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import path "core:path/filepath"
import "core:slice"
import "core:strings"
import "vendor:cgltf"

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
  material_handle: MaterialHandle,
}

@(private = "file")
SkinData :: struct {
  bones:         []Bone,
  root_bone_idx: u32,
}

TextureFromDataAllocator :: #type proc(
  pixel_data: []u8,
) -> (
  handle: Image2DHandle,
  ok: bool,
)

Texture2DRefProc :: #type proc(handle: Image2DHandle) -> bool

load_gltf :: proc(
  world: ^World,
  create_texture_from_data: TextureFromDataAllocator,
  path: string,
) -> (
  nodes: [dynamic]NodeHandle,
  ret: cgltf.result,
) {
  // step 0: cgltf
  gltf_path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
  options: cgltf.options
  gltf_data, parse_result := cgltf.parse_file(options, gltf_path_cstr)
  if parse_result != .success {
    return nodes, parse_result
  }
  defer cgltf.free(gltf_data)
  result := cgltf.result.success
  if len(gltf_data.buffers) > 0 {
    result = cgltf.load_buffers(options, gltf_data, gltf_path_cstr)
    if result != .success {
      return nodes, result
    }
  }
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
    map[^cgltf.texture]Image2DHandle,
    context.temp_allocator,
  )
  material_cache := make(
    map[^cgltf.material]MaterialHandle,
    context.temp_allocator,
  )
  load_textures_batch(
    world,
    create_texture_from_data,
    path,
    manifest.unique_textures[:],
    &texture_cache,
  ) or_return
  load_materials_batch(
    world,
    manifest.unique_materials[:],
    &texture_cache,
    &material_cache,
  ) or_return
  // step 3: Geometry Processing
  geometry_cache := make(map[^cgltf.mesh]GeometryData, context.temp_allocator)
  defer for _, geometry_data in geometry_cache {
    geometry.delete_geometry(geometry_data.geometry)
  }
  mesh_skinning_map := make(map[^cgltf.mesh]bool, context.temp_allocator)
  for &node in gltf_data.nodes do if node.mesh != nil && node.skin != nil {
    mesh_skinning_map[node.mesh] = true
  }
  for mesh in manifest.meshes do if mesh != nil {
    is_skinned := mesh in mesh_skinning_map
    geometry_data := load_mesh_primitives(mesh, &material_cache, is_skinned) or_return
    geometry_cache[mesh] = geometry_data
    log.infof("Processed mesh with %d vertices, %d indices", len(geometry_data.geometry.vertices), len(geometry_data.geometry.indices))
  }
  // step 4: Skinning Processing
  skin_cache := make(map[^cgltf.skin]SkinData, context.temp_allocator)
  load_skins(world, gltf_data, manifest.skins[:], &skin_cache)
  // step 5: Scene Construction
  construct_scene(
    world,
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
  texture_set := make(map[^cgltf.texture]bool, context.temp_allocator)
  material_set := make(map[^cgltf.material]bool, context.temp_allocator)
  mesh_set := make(map[^cgltf.mesh]bool, context.temp_allocator)
  skin_set := make(map[^cgltf.skin]bool, context.temp_allocator)
  for &node in gltf_data.nodes do if node.mesh != nil && node.mesh not_in mesh_set {
    append(&manifest.meshes, node.mesh)
    mesh_set[node.mesh] = true
    if node.skin != nil && node.skin not_in skin_set {
      append(&manifest.skins, node.skin)
      skin_set[node.skin] = true
    }
    for &primitive in node.mesh.primitives do if primitive.material != nil && primitive.material not_in material_set {
      append(&manifest.unique_materials, primitive.material)
      material_set[primitive.material] = true
      mat := primitive.material
      if tex := mat.pbr_metallic_roughness.base_color_texture.texture; tex != nil && tex not_in texture_set {
        append(&manifest.unique_textures, tex)
        texture_set[tex] = true
      }
      if mat.has_pbr_metallic_roughness {
        if tex := mat.pbr_metallic_roughness.metallic_roughness_texture.texture; tex != nil && tex not_in texture_set {
          append(&manifest.unique_textures, tex)
          texture_set[tex] = true
        }
      }
      if tex := mat.normal_texture.texture; tex != nil && tex not_in texture_set {
        append(&manifest.unique_textures, tex)
        texture_set[tex] = true
      }
      if tex := mat.emissive_texture.texture; tex != nil && tex not_in texture_set {
        append(&manifest.unique_textures, tex)
        texture_set[tex] = true
      }
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
  create_texture_from_data: TextureFromDataAllocator,
  gltf_path: string,
  textures: []^cgltf.texture,
  cache: ^map[^cgltf.texture]Image2DHandle,
) -> cgltf.result {
  for texture in textures do if texture != nil && texture.image_ != nil {
    pixel_data: []u8
    own_pixel_data: bool
    defer if own_pixel_data do delete(pixel_data)
    if texture.image_.uri != nil {
      texture_path_str := path.join({path.dir(gltf_path), string(texture.image_.uri)})
      ok: bool
      pixel_data, ok = os.read_entire_file(texture_path_str)
      own_pixel_data = true
      if !ok do return .file_not_found
    } else if texture.image_.buffer_view != nil {
      view := texture.image_.buffer_view
      src_data_ptr := mem.ptr_offset(cast(^u8)view.buffer.data, view.offset)
      pixel_data = slice.from_ptr(src_data_ptr, int(view.size))
      own_pixel_data = false
    } else {
      continue
    }
    handle, ok := create_texture_from_data(pixel_data)
    if !ok do return .io_error
    cache[texture] = handle
    log.infof("Created texture %v", handle)
  }
  return .success
}

@(private = "file")
load_materials_batch :: proc(
  world: ^World,
  materials: []^cgltf.material,
  texture_cache: ^map[^cgltf.texture]Image2DHandle,
  material_cache: ^map[^cgltf.material]MaterialHandle,
) -> (
  ret: cgltf.result,
) {
  ret = .success
  for gltf_mat in materials do if gltf_mat != nil {
    albedo, metallic_roughness, normal, emissive, occlusion, features := load_material_textures(gltf_mat, texture_cache)
    defer if ret != .success {
      // TODO: clean up textures
    }
    material_handle, ok := create_material(world, features, .PBR, albedo, metallic_roughness, normal, emissive, occlusion)
    if !ok do return .invalid_gltf
    material, material_ok := cont.get(world.materials, material_handle)
    if !material_ok do return .invalid_gltf
    stage_material_data(&world.staging, material_handle)
    material_cache[gltf_mat] = material_handle
    log.infof("Created material %v", material_handle)
  }
  return .success
}

@(private = "file")
load_material_textures :: proc(
  mat: ^cgltf.material,
  cache: ^map[^cgltf.texture]Image2DHandle,
) -> (
  albedo: Image2DHandle,
  metallic_roughness: Image2DHandle,
  normal: Image2DHandle,
  emissive: Image2DHandle,
  occlusion: Image2DHandle,
  features: ShaderFeatureSet,
) {
  if mat.has_pbr_metallic_roughness {
    if tex := mat.pbr_metallic_roughness.metallic_roughness_texture.texture;
       tex != nil && tex in cache {
      metallic_roughness = cache[tex]
      features |= {.METALLIC_ROUGHNESS_TEXTURE}
    }
  }
  if tex := mat.pbr_metallic_roughness.base_color_texture.texture;
     tex != nil && tex in cache {
    albedo = cache[tex]
    features |= {.ALBEDO_TEXTURE}
  }
  if tex := mat.normal_texture.texture; tex != nil && tex in cache {
    normal = cache[tex]
    features |= {.NORMAL_TEXTURE}
  }
  if tex := mat.emissive_texture.texture; tex != nil && tex in cache {
    emissive = cache[tex]
    features |= {.EMISSIVE_TEXTURE}
  }
  if tex := mat.occlusion_texture.texture; tex != nil && tex in cache {
    occlusion = cache[tex]
    features |= {.OCCLUSION_TEXTURE}
  }
  return
}

@(private = "file")
load_mesh_primitives :: proc(
  mesh: ^cgltf.mesh,
  cache: ^map[^cgltf.material]MaterialHandle,
  include_skinning: bool,
) -> (
  GeometryData,
  cgltf.result,
) {
  primitives := mesh.primitives
  if len(primitives) == 0 do return {}, .invalid_gltf
  material_handle: MaterialHandle
  if mat := primitives[0].material; mat != nil && mat in cache {
    material_handle = cache[mat]
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
    load_vertex_attributes(&prim, vertices, skinnings)
    append(&combined_vertices, ..vertices[:])
    if include_skinning {
      append(&combined_skinnings, ..skinnings[:])
    }
    // TODO: optimize this, resize combined_indices and directly mutate the element, no more copy
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
    } else {
      indices := make([]u32, vertices_num, context.temp_allocator)
      for i in 0 ..< vertices_num {
        indices[i] = vertex_offset + u32(i)
      }
      append(&combined_indices, ..indices[:])
    }
  }
  // TODO: optimize this, find a way to avoid cloning
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
load_vertex_attributes :: proc(
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
load_skins :: proc(
  world: ^World,
  gltf_data: ^cgltf.data,
  skins: []^cgltf.skin,
  skin_cache: ^map[^cgltf.skin]SkinData,
) {
  for gltf_skin in skins do if gltf_skin != nil {
    bones := make([]Bone, len(gltf_skin.joints))
    for joint_node, i in gltf_skin.joints {
      bones[i].name = string(joint_node.name)
      bones[i].inverse_bind_matrix = linalg.MATRIX4F32_IDENTITY
      if gltf_skin.inverse_bind_matrices != nil {
        read := cgltf.accessor_read_float(gltf_skin.inverse_bind_matrices, uint(i), auto_cast &bones[i].inverse_bind_matrix, 16)
        if !read {
          log.warnf("could not load inverse bind matrices for bone #%v", i)
        }
      }
    }
    for joint_node, i in gltf_skin.joints {
      bones[i].children = make([]u32, len(joint_node.children))
      for child, j in joint_node.children {
        if idx, found := slice.linear_search(gltf_skin.joints, child); found {
          bones[i].children[j] = u32(idx)
        }
      }
    }
    bones_with_parent := make([dynamic]u32, 0, context.temp_allocator)
    for bone in bones {
      append(&bones_with_parent, ..bone.children[:])
    }
    root_bone_idx: u32 = 0
    for i in 0 ..< len(bones) {
      if !slice.contains(bones_with_parent[:], u32(i)) {
        root_bone_idx = u32(i)
        break
      }
    }
    skin_cache[gltf_skin] = SkinData {
      bones         = bones,
      root_bone_idx = root_bone_idx,
    }
    log.infof("Processed skin with %d bones, root bone %d", len(bones), root_bone_idx)
  }
}

@(private = "file")
construct_scene :: proc(
  world: ^World,
  gltf_data: ^cgltf.data,
  geometry_cache: ^map[^cgltf.mesh]GeometryData,
  skin_cache: ^map[^cgltf.skin]SkinData,
  nodes: ^[dynamic]NodeHandle,
) -> cgltf.result {
  TraverseEntry :: struct {
    idx:    u32,
    parent: NodeHandle,
  }
  stack := make([dynamic]TraverseEntry, 0, context.temp_allocator)
  bones_with_parent := make([dynamic]u32, 0, context.temp_allocator)
  node_ptr_to_idx_map := make(map[^cgltf.node]u32, context.temp_allocator)
  skin_to_first_mesh := make(
    map[^cgltf.skin]MeshHandle,
    context.temp_allocator,
  )
  for &node, i in gltf_data.nodes {
    node_ptr_to_idx_map[&node] = u32(i)
  }
  for &node in gltf_data.nodes {
    for child_ptr in node.children {
      child_idx := node_ptr_to_idx_map[child_ptr]
      append(&bones_with_parent, child_idx)
    }
  }
  for i in 0 ..< len(gltf_data.nodes) {
    if !slice.contains(bones_with_parent[:], u32(i)) {
      append(&stack, TraverseEntry{idx = u32(i), parent = world.root})
    }
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    gltf_node := &gltf_data.nodes[entry.idx]
    node_handle, node := cont.alloc(&world.nodes, NodeHandle) or_continue
    init_node(node, string(gltf_node.name))
    node.transform = geometry.TRANSFORM_IDENTITY
    if gltf_node.has_matrix {
      node.transform = geometry.decompose_matrix(
        transmute(matrix[4, 4]f32)gltf_node.matrix_,
      )
    } else {
      if gltf_node.has_translation {
        node.transform.position = gltf_node.translation
      }
      if gltf_node.has_rotation {
        node.transform.rotation = transmute(quaternion128)gltf_node.rotation
      }
      if gltf_node.has_scale {
        node.transform.scale = gltf_node.scale
      }
    }
    node.transform.is_dirty = true
    node.parent = entry.parent
    if gltf_node.mesh in geometry_cache {
      geometry_data := geometry_cache[gltf_node.mesh]
      geometry_copy := geometry.Geometry{
        vertices  = slice.clone(geometry_data.geometry.vertices),
        skinnings = slice.clone(geometry_data.geometry.skinnings),
        indices   = slice.clone(geometry_data.geometry.indices),
        aabb      = geometry_data.geometry.aabb,
      }
      mesh_handle: MeshHandle
      if gltf_node.skin in skin_cache {
        skin_data := skin_cache[gltf_node.skin]
        mesh_handle, mesh, alloc_result := create_mesh(
          world,
          geometry_copy,
          true,
        )
        if !alloc_result do continue
        skinning, _ := &mesh.skinning.?
        skinning.bones = make([]Bone, len(skin_data.bones))
        for src_bone, i in skin_data.bones {
          skinning.bones[i] = src_bone
          skinning.bones[i].children = slice.clone(src_bone.children)
          skinning.bones[i].name = strings.clone(src_bone.name)
        }
        skinning.root_bone_index = skin_data.root_bone_idx
        compute_bone_lengths(skinning)
        // Compute and cache bind matrices (inverse of inverse_bind_matrix)
        skinning.bind_matrices = make([]matrix[4, 4]f32, len(skinning.bones))
        for bone, i in skinning.bones {
          skinning.bind_matrices[i] = linalg.matrix4_inverse(bone.inverse_bind_matrix)
        }
        // Compute and cache bone hierarchy depths for visualization
        skinning.bone_depths = calculate_bone_depths(skinning)
        node.attachment = MeshAttachment {
          handle      = mesh_handle,
          material    = geometry_data.material_handle,
          cast_shadow = true,
          skinning    = NodeSkinning{},
        }
        if mesh_attachment, has_mesh := &node.attachment.(MeshAttachment);
           has_mesh {
          if skinning, has_skinning := &mesh_attachment.skinning.?;
             has_skinning {
            skinning.matrices = make([]matrix[4, 4]f32, len(skin_data.bones))
            slice.fill(skinning.matrices, linalg.MATRIX4F32_IDENTITY)
          }
        }
        stage_bone_matrices(&world.staging, node_handle)
        if _, has_first_mesh := skin_to_first_mesh[gltf_node.skin];
           !has_first_mesh {
          skin_to_first_mesh[gltf_node.skin] = mesh_handle
          load_animations(world, gltf_data, gltf_node.skin, mesh_handle)
        }
      } else {
        mesh_handle, _, alloc_result := create_mesh(
          world,
          geometry_copy,
          true,
        )
        if !alloc_result do continue
        node.attachment = MeshAttachment {
          handle      = mesh_handle,
          material    = geometry_data.material_handle,
          cast_shadow = true,
        }
      }
    }
    attach(world.nodes, entry.parent, node_handle)
    if entry.parent == world.root do append(nodes, node_handle)
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
  gltf_data: ^cgltf.data,
  gltf_skin: ^cgltf.skin,
  mesh_handle: MeshHandle,
) -> bool {
  load_keyframe_cubic_spline :: proc "contextless" (
    $T: typeid,
    sampler: ^cgltf.animation_sampler,
    i: uint,
    k: ^anim.CubicSplineKeyframe(T),
  ) -> bool {
    cgltf.accessor_read_float(sampler.input, i, &k.time, 1) or_return
    cgltf.accessor_read_float(
      sampler.output,
      i * 3 + 0,
      auto_cast &k.in_tangent,
      size_of(T) / size_of(f32),
    ) or_return
    cgltf.accessor_read_float(
      sampler.output,
      i * 3 + 1,
      auto_cast &k.value,
      size_of(T) / size_of(f32),
    ) or_return
    cgltf.accessor_read_float(
      sampler.output,
      i * 3 + 2,
      auto_cast &k.out_tangent,
      size_of(T) / size_of(f32),
    ) or_return
    return true
  }
  load_keyframe_step :: proc "contextless" (
    $T: typeid,
    sampler: ^cgltf.animation_sampler,
    i: uint,
    k: ^anim.StepKeyframe(T),
  ) -> bool {
    cgltf.accessor_read_float(sampler.input, i, &k.time, 1) or_return
    cgltf.accessor_read_float(
      sampler.output,
      i,
      auto_cast &k.value,
      size_of(T) / size_of(f32),
    ) or_return
    return true
  }
  load_keyframe_linear :: proc "contextless" (
    $T: typeid,
    sampler: ^cgltf.animation_sampler,
    i: uint,
    k: ^anim.LinearKeyframe(T),
  ) -> bool {
    cgltf.accessor_read_float(sampler.input, i, &k.time, 1) or_return
    cgltf.accessor_read_float(
      sampler.output,
      i,
      auto_cast &k.value,
      size_of(T) / size_of(f32),
    ) or_return
    return true
  }
  mesh := cont.get(world.meshes, mesh_handle)
  if mesh == nil do return false
  skinning := &mesh.skinning.?
  for gltf_anim, i in gltf_data.animations {
    name: string
    if gltf_anim.name != nil {
      name = strings.clone_from_cstring(gltf_anim.name)
    } else {
      name = fmt.tprintf("animation_%d", i)
    }
    clip_handle := create_animation_clip(
      world,
      len(skinning.bones),
      name = name,
    ) or_continue
    clip := cont.get(world.animation_clips, clip_handle)
    for gltf_channel in gltf_anim.channels do if gltf_channel.target_node != nil && gltf_channel.sampler != nil {
      n := gltf_channel.sampler.input.count
      bone_idx := slice.linear_search(gltf_skin.joints, gltf_channel.target_node) or_continue
      channel := &clip.channels[bone_idx]
      #partial switch gltf_channel.target_path {
      case .translation:
        channel.positions = make(type_of(channel.positions), n)
        switch gltf_channel.sampler.interpolation {
        case .cubic_spline:
          for i in 0 ..< n {
            channel.positions[i] = anim.CubicSplineKeyframe([3]f32){}
            load_keyframe_cubic_spline([3]f32, gltf_channel.sampler, i, &channel.positions[i].(anim.CubicSplineKeyframe([3]f32))) or_continue
          }
        case .step:
          for i in 0 ..< n {
            channel.positions[i] = anim.StepKeyframe([3]f32){}
            load_keyframe_step([3]f32, gltf_channel.sampler, i, &channel.positions[i].(anim.StepKeyframe([3]f32))) or_continue
          }
        case .linear:
          for i in 0 ..< n {
            channel.positions[i] = anim.LinearKeyframe([3]f32){}
            load_keyframe_linear([3]f32, gltf_channel.sampler, i, &channel.positions[i].(anim.LinearKeyframe([3]f32))) or_continue
          }
        }
        switch k in slice.last(channel.positions) {
        case anim.CubicSplineKeyframe([3]f32):
          clip.duration = max(clip.duration, k.time)
        case anim.StepKeyframe([3]f32):
          clip.duration = max(clip.duration, k.time)
        case anim.LinearKeyframe([3]f32):
          clip.duration = max(clip.duration, k.time)
        }
      case .rotation:
        channel.rotations = make(type_of(channel.rotations), n)
        switch gltf_channel.sampler.interpolation {
        case .cubic_spline:
          for i in 0 ..< n {
            channel.rotations[i] = anim.CubicSplineKeyframe(quaternion128){}
            load_keyframe_cubic_spline(quaternion128, gltf_channel.sampler, i, &channel.rotations[i].(anim.CubicSplineKeyframe(quaternion128))) or_continue
          }
        case .step:
          for i in 0 ..< n {
            channel.rotations[i] = anim.StepKeyframe(quaternion128){}
            load_keyframe_step(quaternion128, gltf_channel.sampler, i, &channel.rotations[i].(anim.StepKeyframe(quaternion128))) or_continue
          }
        case .linear:
          for i in 0 ..< n {
            channel.rotations[i] = anim.LinearKeyframe(quaternion128){}
            load_keyframe_linear(quaternion128, gltf_channel.sampler, i, &channel.rotations[i].(anim.LinearKeyframe(quaternion128))) or_continue
          }
        }
        switch k in slice.last(channel.rotations) {
        case anim.CubicSplineKeyframe(quaternion128):
          clip.duration = max(clip.duration, k.time)
        case anim.StepKeyframe(quaternion128):
          clip.duration = max(clip.duration, k.time)
        case anim.LinearKeyframe(quaternion128):
          clip.duration = max(clip.duration, k.time)
        }
      case .scale:
        channel.scales = make(type_of(channel.scales), n)
        switch gltf_channel.sampler.interpolation {
        case .cubic_spline:
          for i in 0 ..< n {
            channel.scales[i] = anim.CubicSplineKeyframe([3]f32){}
            load_keyframe_cubic_spline([3]f32, gltf_channel.sampler, i, &channel.scales[i].(anim.CubicSplineKeyframe([3]f32))) or_continue
          }
        case .step:
          for i in 0 ..< n {
            channel.scales[i] = anim.StepKeyframe([3]f32){}
            load_keyframe_step([3]f32, gltf_channel.sampler, i, &channel.scales[i].(anim.StepKeyframe([3]f32))) or_continue
          }
        case .linear:
          for i in 0 ..< n {
            channel.scales[i] = anim.LinearKeyframe([3]f32){}
            load_keyframe_linear([3]f32, gltf_channel.sampler, i, &channel.scales[i].(anim.LinearKeyframe([3]f32))) or_continue
          }
        }
        switch k in slice.last(channel.scales) {
        case anim.CubicSplineKeyframe([3]f32):
          clip.duration = max(clip.duration, k.time)
        case anim.StepKeyframe([3]f32):
          clip.duration = max(clip.duration, k.time)
        case anim.LinearKeyframe([3]f32):
          clip.duration = max(clip.duration, k.time)
        }
      }
    }
  }
  return true
}
