package mjolnir

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import path "core:path/filepath"
import "core:slice"
import "core:strings"

import "core:math/linalg"
import "vendor:cgltf"
import vk "vendor:vulkan"

import "animation"
import "geometry"
import "gpu"
import "resource"

load_gltf :: proc(
  engine: ^Engine,
  path: string,
) -> (
  nodes: [dynamic]Handle,
  ret: cgltf.result,
) {
  gltf_path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
  options: cgltf.options
  gltf_data := cgltf.parse_file(options, gltf_path_cstr) or_return
  defer cgltf.free(gltf_data)
  if len(gltf_data.buffers) > 0 {
    cgltf.load_buffers(options, gltf_data, gltf_path_cstr) or_return
  }
  nodes = make([dynamic]Handle, 0)
  if len(gltf_data.nodes) == 0 {
    return nodes, .success
  }
  // Track bone matrix buffer mapping (1 skin = 1 bone matrix buffer)
  skin_to_bone_offset := make(map[^cgltf.skin]u32, context.temp_allocator)
  // Track which mesh gets animation
  skin_to_first_mesh := make(map[^cgltf.skin]resource.Handle, context.temp_allocator)
  // Track texture deduplication
  texture_to_handle := make(map[^cgltf.texture]resource.Handle, context.temp_allocator)
  // Track material deduplication
  material_to_handle := make(map[^cgltf.material]resource.Handle, context.temp_allocator)
  TraverseEntry :: struct {
    idx:    u32,
    parent: Handle,
  }
  stack := make([dynamic]TraverseEntry, 0, context.temp_allocator)
  is_gltf_child_node: bit_set[0 ..< 128] // Assuming max 128 nodes, TODO: fix this
  node_ptr_to_idx_map := make(map[^cgltf.node]u32, context.temp_allocator)
  for &node, i in gltf_data.nodes {
    node_ptr_to_idx_map[&node] = u32(i)
  }
  for &node in gltf_data.nodes {
    for child_ptr in node.children {
      child_idx := node_ptr_to_idx_map[child_ptr]
      is_gltf_child_node += {int(child_idx)}
    }
  }
  for i in 0 ..< len(gltf_data.nodes) {
    if i not_in is_gltf_child_node {
      append(&stack, TraverseEntry{idx = u32(i), parent = engine.scene.root})
    }
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    gltf_node := &gltf_data.nodes[entry.idx]
    node_handle, node := resource.alloc(&engine.scene.nodes)
    if node == nil do continue
    node.name = string(gltf_node.name)
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
    node.children = make([dynamic]Handle, 0)
    // Attach mesh if present
    if gltf_node.mesh != nil {
      if gltf_node.skin != nil {
        log.infof("Loading skinned mesh %s", string(gltf_node.name))
        mesh_handle, mesh := resource.alloc(&engine.warehouse.meshes)
        data, bones, material, root_bone_idx, res :=
          load_gltf_skinned_primitive(
            engine,
            path,
            gltf_data,
            gltf_node.mesh,
            gltf_node.skin,
            &texture_to_handle,
            &material_to_handle,
          )
        if res == .SUCCESS {
          mesh_init(mesh, &engine.gpu_context, data)
          skinning, _ := &mesh.skinning.?
          skinning.bones = bones
          skinning.root_bone_index = root_bone_idx
          bone_matrix_id: u32
          if existing_offset, found := skin_to_bone_offset[gltf_node.skin];
             found {
            bone_matrix_id = existing_offset
            log.infof(
              "Reusing bone matrix buffer for skin at offset %d",
              bone_matrix_id,
            )
          } else {
            bone_matrix_id = resource.slab_alloc(
              &engine.warehouse.bone_matrix_slab,
              u32(len(bones)),
            )
            skin_to_bone_offset[gltf_node.skin] = bone_matrix_id
            log.infof(
              "Allocated new bone matrix buffer for skin at offset %d with %d bones",
              bone_matrix_id,
              len(bones),
            )
            // Set bind pose for all frames (otherwise zeroed out matrices will cause model to be invisible)
            for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
              l :=
                bone_matrix_id +
                u32(frame_idx) * engine.warehouse.bone_matrix_slab.capacity
              r := l + u32(len(bones))
              bone_matrices := engine.warehouse.bone_buffer.mapped[l:r]
              slice.fill(bone_matrices, linalg.MATRIX4F32_IDENTITY)
            }
          }
          node.attachment = MeshAttachment {
            handle = mesh_handle,
            material = material,
            cast_shadow = true,
            skinning = NodeSkinning{bone_matrix_offset = bone_matrix_id},
          }
          if _, has_first_mesh := skin_to_first_mesh[gltf_node.skin];
             !has_first_mesh {
            skin_to_first_mesh[gltf_node.skin] = mesh_handle
            load_gltf_animations(
              engine,
              gltf_data,
              gltf_node.skin,
              mesh_handle,
            )
            log.infof(
              "Loaded animations for skin on mesh %v (first mesh for this skin)",
              mesh_handle,
            )
          } else {
            log.infof(
              "Skipped animations for mesh %v (skin already has animations on another mesh)",
              mesh_handle,
            )
          }
        } else {
          // Clean up the allocated mesh if skinned primitive loading failed
          if mesh, freed := resource.free(
            &engine.warehouse.meshes,
            mesh_handle,
          ); freed {
            mesh_deinit(mesh, &engine.gpu_context)
          }
        }
      } else {
        log.infof("Loading static mesh %s", string(gltf_node.name))
        mesh_data, mat_handle, res := load_gltf_primitive(
          engine,
          path,
          gltf_data,
          gltf_node.mesh,
          &texture_to_handle,
          &material_to_handle,
        )
        if res != .SUCCESS {
          log.errorf("Failed to process GLTF primitive:", res)
          continue
        }
        log.infof(
          "Initializing static mesh with %d vertices, %d indices %v",
          len(mesh_data.vertices),
          len(mesh_data.indices),
          mesh_data.skinnings,
        )
        mesh_handle, _, ret := create_mesh(
          &engine.gpu_context,
          &engine.warehouse,
          mesh_data,
        )
        if ret != .SUCCESS {
          log.error("Failed to create static mesh ", ret)
          continue
        }
        node.attachment = MeshAttachment {
          handle      = mesh_handle,
          material    = mat_handle,
          cast_shadow = true,
        }
        log.infof(
          "Static mesh loaded successfully with material %v",
          mat_handle,
        )
      }
    }
    attach(engine.scene.nodes, entry.parent, node_handle)
    if entry.parent == engine.scene.root {
      append(&nodes, node_handle)
    }
    for child_ptr in gltf_node.children {
      if child_idx, found := node_ptr_to_idx_map[child_ptr]; found {
        append(&stack, TraverseEntry{idx = child_idx, parent = node_handle})
      }
    }
  }
  log.infof("GLTF loading complete:")
  log.infof("  - Unique skins: %d", len(skin_to_bone_offset))
  log.infof("  - Skins with animations: %d", len(skin_to_first_mesh))
  log.infof("  - Unique textures: %d", len(texture_to_handle))
  log.infof("  - Unique materials: %d", len(material_to_handle))
  return nodes, .success
}

load_gltf_texture :: proc(
  engine: ^Engine,
  gltf_path: string,
  gltf_data: ^cgltf.data,
  gltf_texture: ^cgltf.texture,
  texture_cache: ^map[^cgltf.texture]resource.Handle,
) -> (
  tex_handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  if gltf_texture == nil {
    ret = .ERROR_UNKNOWN
    return
  }

  // Check if texture already loaded
  if existing_handle, found := texture_cache[gltf_texture]; found {
    tex_handle = existing_handle
    ret = .SUCCESS
    log.infof("Reusing texture %v", tex_handle)
    return
  }

  if gltf_texture.image_ == nil {
    ret = .ERROR_UNKNOWN
    return
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
      log.errorf("Failed to read texture file '%s'\n", texture_path_str)
      ret = .ERROR_UNKNOWN
      return
    }
  } else if gltf_image.buffer_view != nil {
    view := gltf_image.buffer_view
    buffer := view.buffer
    src_data_ptr := mem.ptr_offset(cast(^u8)buffer.data, view.offset)
    pixel_data = slice.from_ptr(src_data_ptr, int(view.size))
    pixel_data = slice.clone(pixel_data)
  } else {
    ret = .ERROR_UNKNOWN
    return
  }
  log.infof("Creating new texture from %d bytes", len(pixel_data))
  tex_handle, texture = create_texture(
    &engine.gpu_context,
    &engine.warehouse,
    pixel_data,
  ) or_return
  delete(pixel_data)
  // Cache the texture
  texture_cache[gltf_texture] = tex_handle
  ret = .SUCCESS
  return
}

load_gltf_pbr_textures :: proc(
  engine: ^Engine,
  gltf_path: string,
  gltf_data: ^cgltf.data,
  gltf_material: ^cgltf.material,
  texture_cache: ^map[^cgltf.texture]resource.Handle,
) -> (
  albedo_handle: Handle,
  metallic_roughness_handle: Handle,
  normal_handle: Handle,
  emissive_handle: Handle,
  features: ShaderFeatureSet,
  ret: vk.Result,
) {
  if gltf_material == nil {
    ret = .ERROR_UNKNOWN
    return
  }
  log.info("loading pbr textures")
  albedo_handle, _ = load_gltf_texture(
    engine,
    gltf_path,
    gltf_data,
    gltf_material.pbr_metallic_roughness.base_color_texture.texture,
    texture_cache,
  ) or_return
  features |= {.ALBEDO_TEXTURE}

  if gltf_material.has_pbr_metallic_roughness {
    pbr_info := gltf_material.pbr_metallic_roughness
    if pbr_info.metallic_roughness_texture.texture != nil {
      gltf_texture := pbr_info.metallic_roughness_texture.texture
      if gltf_texture.image_ != nil {
        gltf_image := gltf_texture.image_
        pixel_data: []u8
        if gltf_image.uri != nil {
          texture_path_str := path.join(
            {path.dir(gltf_path), string(gltf_image.uri)},
          )
          ok: bool
          pixel_data, ok = os.read_entire_file(texture_path_str)
          if !ok {
            log.errorf(
              "Failed to read metallic-roughness texture file '%s'\n",
              texture_path_str,
            )
            ret = .ERROR_UNKNOWN
            return
          }
        } else if gltf_image.buffer_view != nil {
          view := gltf_image.buffer_view
          buffer := view.buffer
          src_data_ptr := mem.ptr_offset(cast(^u8)buffer.data, view.offset)
          pixel_data = slice.from_ptr((^u8)(src_data_ptr), int(view.size))
          pixel_data = slice.clone(pixel_data)
        } else {
          ret = .ERROR_UNKNOWN
          return
        }
        metallic_roughness_handle, _ = create_texture(
          &engine.gpu_context,
          &engine.warehouse,
          pixel_data,
        ) or_return
        features |= {.METALLIC_ROUGHNESS_TEXTURE}
        delete(pixel_data)
      }
    }
  }
  if gltf_material.normal_texture.texture != nil {
    normal_handle, _ = load_gltf_texture(
      engine,
      gltf_path,
      gltf_data,
      gltf_material.normal_texture.texture,
      texture_cache,
    ) or_return
    features |= {.NORMAL_TEXTURE}
  }
  if gltf_material.emissive_texture.texture != nil {
    emissive_handle, _ = load_gltf_texture(
      engine,
      gltf_path,
      gltf_data,
      gltf_material.emissive_texture.texture,
      texture_cache,
    ) or_return
    features |= {.EMISSIVE_TEXTURE}
  }
  ret = .SUCCESS
  return
}

load_gltf_primitive :: proc(
  engine: ^Engine,
  path: string,
  gltf_data: ^cgltf.data,
  gltf_mesh: ^cgltf.mesh,
  texture_cache: ^map[^cgltf.texture]resource.Handle,
  material_cache: ^map[^cgltf.material]resource.Handle,
) -> (
  mesh_data: geometry.Geometry,
  material_handle: resource.Handle,
  ret: vk.Result,
) {
  primitives := gltf_mesh.primitives
  if len(primitives) == 0 {
    ret = .ERROR_UNKNOWN
    return
  }
  primitive := &primitives[0]
  if existing_handle, found := material_cache[primitive.material]; found {
    material_handle = existing_handle
    log.infof("Reusing material %v", material_handle)
  } else {
    albedo_handle, metallic_roughness_handle, normal_handle, emissive_handle, features :=
      load_gltf_pbr_textures(
        engine,
        path,
        gltf_data,
        primitive.material,
        texture_cache,
      ) or_return
    material_handle, _ = create_material(
      &engine.warehouse,
      features,
      .PBR,
      albedo_handle,
      metallic_roughness_handle,
      normal_handle,
      emissive_handle,
    ) or_return
    material_cache[primitive.material] = material_handle
    log.infof("Created new material %v", material_handle)
  }
  vertices_num := primitive.attributes[0].data.count
  vertices := make([]geometry.Vertex, vertices_num)
  for attribute in primitive.attributes {
    accessor := attribute.data
    if accessor.count != vertices_num {
      log.errorf(
        "Warning: Attribute '%v' count (%d) does not match position count (%d)\n",
        attribute.type,
        accessor.count,
        vertices_num,
      )
    }
    floats_data := unpack_accessor_floats_flat(accessor)
    #partial switch attribute.type {
    case .position:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        vertices[i].position = {
          floats_data[i * 3 + 0],
          floats_data[i * 3 + 1],
          floats_data[i * 3 + 2],
        }
      }
    case .normal:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        vertices[i].normal = {
          floats_data[i * 3 + 0],
          floats_data[i * 3 + 1],
          floats_data[i * 3 + 2],
        }
      }
    case .texcoord:
      if attribute.index == 0 {
        for i in 0 ..< min(int(accessor.count), len(vertices)) {
          vertices[i].uv = {floats_data[i * 2 + 0], floats_data[i * 2 + 1]}
        }
      }
    case .tangent:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        vertices[i].tangent = {
          floats_data[i * 4 + 0],
          floats_data[i * 4 + 1],
          floats_data[i * 4 + 2],
          floats_data[i * 4 + 3],
        }
      }
    }
  }
  indices: []u32
  if primitive.indices != nil {
    indices = make([]u32, primitive.indices.count)
    read := cgltf.accessor_unpack_indices(
      primitive.indices,
      raw_data(indices),
      size_of(u32),
      primitive.indices.count,
    )
    if read != primitive.indices.count {
      log.errorf(
        "Failed to read indices from GLTF primitive. read %d, need %d\n",
        read,
        primitive.indices.count,
      )
      ret = .ERROR_UNKNOWN
      return
    }
  }
  mesh_data = geometry.make_geometry(vertices, indices)
  return mesh_data, material_handle, .SUCCESS
}

load_gltf_skinned_primitive :: proc(
  engine: ^Engine,
  path: string,
  gltf_data: ^cgltf.data,
  gltf_mesh: ^cgltf.mesh,
  gltf_skin: ^cgltf.skin,
  texture_cache: ^map[^cgltf.texture]resource.Handle,
  material_cache: ^map[^cgltf.material]resource.Handle,
) -> (
  geometry_data: geometry.Geometry,
  engine_bones: []Bone,
  mat_handle: resource.Handle,
  root_bone_idx: u32,
  ret: vk.Result, // TODO: too many return values, consider refactor this
) {
  primitives := gltf_mesh.primitives
  if len(primitives) == 0 {
    ret = .ERROR_UNKNOWN
    return
  }
  primitive := &primitives[0]
  log.infof("Creating texture for skinned material...")
  if existing_handle, found := material_cache[primitive.material]; found {
    mat_handle = existing_handle
    log.infof("Reusing skinned material %v", mat_handle)
  } else {
    albedo_handle, metallic_roughness_handle, normal_handle, emissive_handle, features :=
      load_gltf_pbr_textures(
        engine,
        path,
        gltf_data,
        primitive.material,
        texture_cache,
      ) or_return
    mat_handle, _ = create_material(
      &engine.warehouse,
      features | {.SKINNING},
      .PBR,
      albedo_handle,
      metallic_roughness_handle,
      normal_handle,
      emissive_handle,
    ) or_return
    material_cache[primitive.material] = mat_handle
    log.infof(
      "Creating skinned material with PBR textures %v/%v/%v/%v/%v -> %v",
      albedo_handle,
      metallic_roughness_handle,
      normal_handle,
      emissive_handle,
      mat_handle,
    )
  }
  num_vertices := primitive.attributes[0].data.count
  vertices := make([]geometry.Vertex, num_vertices)
  skinnings := make([]geometry.SkinningData, num_vertices)
  attributes := primitive.attributes
  for attribute in attributes {
    accessor := attribute.data
    if accessor.count != num_vertices {
      log.errorf(
        "Warning: Skinned attribute '%v' count (%d) does not match position count (%d)\n",
        attribute.type,
        accessor.count,
        num_vertices,
      )
    }
    data := unpack_accessor_floats_flat(accessor)
    #partial switch attribute.type {
    case .position:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        vertices[i].position = {
          data[i * 3 + 0],
          data[i * 3 + 1],
          data[i * 3 + 2],
        }
      }
    case .normal:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        vertices[i].normal = {
          data[i * 3 + 0],
          data[i * 3 + 1],
          data[i * 3 + 2],
        }
      }
    case .texcoord:
      if attribute.index == 0 {
        for i in 0 ..< min(int(accessor.count), len(vertices)) {
          vertices[i].uv = {data[i * 2 + 0], data[i * 2 + 1]}
        }
      }
    case .tangent:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        vertices[i].tangent = {
          data[i * 4 + 0],
          data[i * 4 + 1],
          data[i * 4 + 2],
          data[i * 4 + 3],
        }
      }
    case .joints:
      // log.infof("Loading joints with accessor %v", accessor)
      if attribute.index == 0 {
        n := accessor.count
        for i in 0 ..< min(int(n), len(vertices)) {
          read := cgltf.accessor_read_uint(
            accessor,
            uint(i),
            raw_data(skinnings[i].joints[:]),
            len(skinnings[i].joints),
          )
          if !read {
            log.errorf("Failed to read joints from GLTF primitive.\n")
          }
        }
      }
    case .weights:
      if attribute.index == 0 {
        for i in 0 ..< min(int(accessor.count), len(vertices)) {
          skinnings[i].weights = {
            data[i * 4 + 0],
            data[i * 4 + 1],
            data[i * 4 + 2],
            data[i * 4 + 3],
          }
        }
      }
    }
  }
  // log.infof("Joints %v", vertices[len(vertices)-20:])
  indices: []u32
  if primitive.indices != nil {
    indices = make([]u32, primitive.indices.count)
    read := cgltf.accessor_unpack_indices(
      primitive.indices,
      raw_data(indices),
      size_of(u32),
      primitive.indices.count,
    )
    if read != primitive.indices.count {
      log.errorf(
        "Failed to read indices from GLTF primitive. read %d, need %d\n",
        read,
        primitive.indices.count,
      )
      ret = .ERROR_UNKNOWN
      return
    }
  }
  geometry_data = geometry.make_geometry(vertices, indices, skinnings)
  engine_bones = make([]Bone, len(gltf_skin.joints))
  for joint_node, i in gltf_skin.joints {
    engine_bones[i].name = string(joint_node.name)
    if gltf_skin.inverse_bind_matrices != nil {
      ibm_floats: [16]f32
      read := cgltf.accessor_read_float(
        gltf_skin.inverse_bind_matrices,
        uint(i),
        raw_data(ibm_floats[:]),
        16,
      )
      if read {
        engine_bones[i].inverse_bind_matrix = geometry.matrix_from_arr(
          ibm_floats,
        )
      }
    } else {
      engine_bones[i].inverse_bind_matrix = linalg.MATRIX4F32_IDENTITY
    }
  }
  for joint_node, i in gltf_skin.joints {
    engine_bones[i].children = make([]u32, len(joint_node.children))
    for child, j in joint_node.children {
      if idx, found := slice.linear_search(gltf_skin.joints, child); found {
        engine_bones[i].children[j] = u32(idx)
      }
    }
  }
  is_child_bone: bit_set[0 ..< 128]
  for bone in engine_bones {
    for child_idx in bone.children {
      is_child_bone += {int(child_idx)}
    }
  }
  found_root := false
  for i in 0 ..< len(engine_bones) {
    if i not_in is_child_bone {
      root_bone_idx = u32(i)
      found_root = true
      break
    }
  }
  if !found_root && len(engine_bones) > 0 {
    log.errorf(
      "Warning: Could not determine unique root bone for skin, using index 0.\n",
    )
  }
  ret = .SUCCESS
  return
}

// Helper to unpack accessor data into a flat []f32. Caller must free the returned slice.
unpack_accessor_floats_flat :: proc(accessor: ^cgltf.accessor) -> []f32 {
  if accessor == nil {
    return nil
  }
  n := accessor.count * cgltf.num_components(accessor.type)
  ret := make([]f32, n)
  _ = cgltf.accessor_unpack_floats(accessor, raw_data(ret), n)
  return ret
}

load_gltf_animations :: proc(
  engine: ^Engine,
  gltf_data: ^cgltf.data,
  gltf_skin: ^cgltf.skin,
  engine_mesh_handle: resource.Handle,
) -> bool {
  mesh := mesh(engine, engine_mesh_handle)
  skinning := &mesh.skinning.?
  skinning.animations = make([]animation.Clip, len(gltf_data.animations))
  for gltf_anim, i in gltf_data.animations {
    clip := &skinning.animations[i]
    if gltf_anim.name != nil {
      clip.name = strings.clone_from_cstring(gltf_anim.name)
    } else {
      clip.name = fmt.tprintf("animation_%d", i)
    }
    log.infof(
      "\nAllocating animation channels for %d bones",
      len(skinning.bones),
    )
    clip.channels = make([]animation.Channel, len(skinning.bones))
    max_time: f32 = 0.0
    for gltf_channel in gltf_anim.channels {
      if gltf_channel.target_node == nil || gltf_channel.sampler == nil {
        continue
      }
      n := gltf_channel.sampler.input.count
      // note: if this get slow, consider using a hash map
      bone_idx := slice.linear_search(
        gltf_skin.joints,
        gltf_channel.target_node,
      ) or_continue
      engine_channel := &clip.channels[bone_idx]
      time_data := unpack_accessor_floats_flat(gltf_channel.sampler.input)
      // defer free(time_data)
      max_time = max(max_time, slice.max(time_data))
      // log.infof(
      //   "Bone animation %s %v: keyframe count %d",
      //   string(gltf_channel.target_node.name),
      //   gltf_channel.target_path,
      //   n,
      // )
      switch gltf_channel.target_path {
      case .translation:
        engine_channel.positions = make(type_of(engine_channel.positions), n)
        values := unpack_accessor_floats_flat(gltf_channel.sampler.output)
        // defer free(values)
        for i in 0 ..< len(time_data) {
          engine_channel.positions[i] = {
            time  = time_data[i],
            value = {values[i * 3 + 0], values[i * 3 + 1], values[i * 3 + 2]},
          }
        }
      case .rotation:
        engine_channel.rotations = make(type_of(engine_channel.rotations), n)
        values := unpack_accessor_floats_flat(gltf_channel.sampler.output)
        // defer free(values)
        for i in 0 ..< len(time_data) {
          engine_channel.rotations[i] = {
            time  = time_data[i],
            value = quaternion(
              x = values[i * 4 + 0],
              y = values[i * 4 + 1],
              z = values[i * 4 + 2],
              w = values[i * 4 + 3],
            ),
          }
        }
      case .scale:
        engine_channel.scales = make(type_of(engine_channel.scales), n)
        values := unpack_accessor_floats_flat(gltf_channel.sampler.output)
        // defer free(values)
        for i in 0 ..< len(time_data) {
          engine_channel.scales[i] = {
            time  = time_data[i],
            value = {values[i * 3 + 0], values[i * 3 + 1], values[i * 3 + 2]},
          }
        }
      case .weights:
        log.infof("Weights not handled for bone animation here")
      case .invalid:
        log.infof("Invalid animation channel type")
      }
    }
    clip.duration = max_time
    // log.infof("Animation %s duration: %f", clip.name, clip.duration, clip.channels)
  }
  return true
}
