package mjolnir

import "core:fmt"
import "core:mem"
import "core:os"
import path "core:path/filepath"
import "core:slice"
import "core:strings"

import linalg "core:math/linalg"
import cgltf "vendor:cgltf"
import vk "vendor:vulkan"

import "geometry"
import "resource"

load_gltf :: proc(
  engine: ^Engine,
  path: string,
) -> (
  root_node_handles: []Handle,
  ret: cgltf.result,
) {
  gltf_path_cstr := strings.clone_to_cstring(path)
  defer delete(gltf_path_cstr)

  options := cgltf.options{}
  gltf_data := cgltf.parse_file(options, gltf_path_cstr) or_return
  defer cgltf.free(gltf_data)

  if len(gltf_data.buffers) > 0 {
    cgltf.load_buffers(options, gltf_data, gltf_path_cstr) or_return
  }

  created_root_handles := make([dynamic]resource.Handle, 0)
  if len(gltf_data.nodes) == 0 {
    return created_root_handles[:], .success
  }

  TraverseEntry :: struct {
    idx:    u32,
    parent: Handle,
  }
  stack := make([dynamic]TraverseEntry, 0)
  defer delete(stack)

  is_gltf_child_node: bit_set[0 ..< 128] // Assuming max 128 nodes, TODO: fix this
  node_ptr_to_idx_map := make(map[^cgltf.node]u32)
  for &node, i in gltf_data.nodes {
    node_ptr_to_idx_map[&node] = u32(i)
  }
  defer delete(node_ptr_to_idx_map)
  for &node in gltf_data.nodes {
    for child_ptr in node.children {
      child_idx := node_ptr_to_idx_map[child_ptr]
      is_gltf_child_node += {int(child_idx)}
    }
  }
  for i in 0 ..< len(gltf_data.nodes) {
    if i not_in is_gltf_child_node {
      fmt.printfln("Queuing node #%d %s", i, gltf_data.nodes[i].name)
      append(&stack, TraverseEntry{idx = u32(i), parent = engine.scene.root})
    }
  }

  for len(stack) > 0 {
    entry := pop(&stack)
    g_node := &gltf_data.nodes[entry.idx]
    node_handle, node := resource.alloc(&engine.nodes)
    if node == nil {
      continue
    }
    node.name = string(g_node.name)
    node.transform = geometry.transform_identity()
    if g_node.has_matrix {
      geometry.decompose_matrix(
        &node.transform,
        geometry.matrix_from_slice(g_node.matrix_),
      )
    } else {
      if g_node.has_translation {
        node.transform.position = g_node.translation
      }
      if g_node.has_rotation {
        node.transform.rotation = quaternion(
          x = g_node.rotation[0],
          y = g_node.rotation[1],
          z = g_node.rotation[2],
          w = g_node.rotation[3],
        )
      }
      if g_node.has_scale {
        node.transform.scale = g_node.scale
      }
      fmt.printfln(
        "Node %s: translation %v, rotation %v, scale %v",
        string(g_node.name),
        g_node.translation,
        g_node.rotation,
        g_node.scale,
      )
    }
    node.parent = entry.parent
    node.children = make([dynamic]Handle, 0)
    // Attach mesh if present
    if g_node.mesh != nil {
      if g_node.skin != nil {
        fmt.printfln("Loading skinned mesh %s", string(g_node.name))
        mesh_handle, mesh := resource.alloc(&engine.skeletal_meshes)
        data, bones, material, root_bone_idx, bone_map, res :=
          load_gltf_skinned_primitive(
            engine,
            path,
            gltf_data,
            g_node.mesh,
            g_node.skin,
          )
        if res == .SUCCESS {
          skeletal_mesh_init(mesh, &data, &engine.ctx)
          mesh.material = material
          mesh.bones = bones
          mesh.root_bone_index = root_bone_idx

          // Initialize pose for the mesh
          pose: Pose
          pose_init(&pose, len(bones), &engine.ctx)

          // Create the attachment with initialized pose
          node.attachment = NodeSkeletalMeshAttachment {
              handle = mesh_handle,
              pose   = pose,
            }

          // Process animations for this mesh
          load_gltf_animations(
            engine,
            gltf_data,
            g_node.skin,
            mesh_handle,
            bone_map,
          )

          // fmt.printfln("Skinned mesh loaded successfully with %d animation %v", len(mesh.animations), mesh.animations)


          // Set initial pose to bind pose
          for bone_idx := 0; bone_idx < len(bones); bone_idx += 1 {
            pose.bone_matrices[bone_idx] = linalg.MATRIX4F32_IDENTITY
          }
          pose_flush(&pose)
        }
      } else {
        fmt.printfln("Loading static mesh %s", string(g_node.name))
        fmt.printfln("Processing static mesh data...")
        mesh_data, mat_handle, res := load_gltf_primitive(
          engine,
          path,
          gltf_data,
          g_node.mesh,
        )
        if res != .SUCCESS {
          fmt.eprintln("Failed to process GLTF primitive:", res)
          continue
        }

        fmt.printfln(
          "Initializing static mesh with %d vertices, %d indices",
          len(mesh_data.vertices),
          len(mesh_data.indices),
        )

        mesh_handle := create_static_mesh(engine, &mesh_data, mat_handle)

        node.attachment = NodeStaticMeshAttachment {
          handle = mesh_handle,
        }
        fmt.printfln(
          "Static mesh loaded successfully with material %v",
          mat_handle,
        )
      }
    }
    // Parent this node to its parent
    attach(&engine.nodes, entry.parent, node_handle)
    if entry.parent == engine.scene.root {
      // If this is a root node, add it to the created handles
      append(&created_root_handles, node_handle)
    }
    // Push children to stack
    for child_ptr in g_node.children {
      if child_idx, found := node_ptr_to_idx_map[child_ptr]; found {
        append(&stack, TraverseEntry{idx = child_idx, parent = node_handle})
      }
    }
  }
  return created_root_handles[:], .success
}


// Helper: Load a GLTF texture and create an engine texture handle using the procedural API
load_gltf_texture :: proc(
  engine: ^Engine,
  gltf_path: string,
  gltf_data: ^cgltf.data,
  g_texture: ^cgltf.texture,
) -> (
  tex_handle: Handle,
  texture: ^Texture,
  ret: vk.Result,
) {
  if g_texture == nil || g_texture.image_ == nil {
    ret = .ERROR_UNKNOWN
    return
  }
  g_image := g_texture.image_
  pixel_data: []u8
  if g_image.uri != nil {
    texture_path_str := path.join({path.dir(gltf_path), string(g_image.uri)})
    ok: bool
    pixel_data, ok = os.read_entire_file(texture_path_str)
    if !ok {
      fmt.eprintf("Failed to read texture file '%s'\n", texture_path_str)
      ret = .ERROR_UNKNOWN
      return
    }
  } else if g_image.buffer_view != nil {
    view := g_image.buffer_view
    buffer := view.buffer
    src_data_ptr := mem.ptr_offset(cast(^u8)buffer.data, view.offset)
    pixel_data = slice.from_ptr((^u8)(src_data_ptr), int(view.size))
    pixel_data = slice.clone(pixel_data)
  } else {
    ret = .ERROR_UNKNOWN
    return
  }
  fmt.printfln("Creating texture from %d bytes", len(pixel_data))
  tex_handle, texture = create_texture_from_data(engine, pixel_data) or_return
  delete(pixel_data)
  ret = .SUCCESS
  return
}

// Helper: Load a GLTF texture and create an engine texture handle using the procedural API
load_gltf_pbr_textures :: proc(
  engine: ^Engine,
  gltf_path: string,
  gltf_data: ^cgltf.data,
  g_material: ^cgltf.material,
) -> (
  albedo_handle: Handle,
  metallic_roughness_handle: Handle,
  normal_handle: Handle,
  displacement_handle: Handle,
  emissive_handle: Handle,
  features: u32,
  ret: vk.Result,
) {
  if g_material == nil {
    ret = .ERROR_UNKNOWN
    return
  }
  albedo_handle, _ = load_gltf_texture(
    engine,
    gltf_path,
    gltf_data,
    g_material.pbr_metallic_roughness.base_color_texture.texture,
  ) or_return
  features |= SHADER_FEATURE_ALBEDO_TEXTURE

  if g_material.has_pbr_metallic_roughness {
    pbr_info := g_material.pbr_metallic_roughness
    // Load metallic-roughness texture (GLTF packs both in one texture, B=metallic, G=roughness)
    if pbr_info.metallic_roughness_texture.texture != nil {
      g_texture := pbr_info.metallic_roughness_texture.texture
      if g_texture.image_ != nil {
        g_image := g_texture.image_
        pixel_data: []u8
        if g_image.uri != nil {
          texture_path_str := path.join(
            {path.dir(gltf_path), string(g_image.uri)},
          )
          ok: bool
          pixel_data, ok = os.read_entire_file(texture_path_str)
          if !ok {
            fmt.eprintf(
              "Failed to read metallic-roughness texture file '%s'\n",
              texture_path_str,
            )
            ret = .ERROR_UNKNOWN
            return
          }
        } else if g_image.buffer_view != nil {
          view := g_image.buffer_view
          buffer := view.buffer
          src_data_ptr := mem.ptr_offset(cast(^u8)buffer.data, view.offset)
          pixel_data = slice.from_ptr((^u8)(src_data_ptr), int(view.size))
          pixel_data = slice.clone(pixel_data)
        } else {
          ret = .ERROR_UNKNOWN
          return
        }
        // For now, use the same texture for both metallic and roughness
        metallic_roughness_handle, _ = create_texture_from_data(
          engine,
          pixel_data,
        ) or_return
        features |= SHADER_FEATURE_METALLIC_ROUGHNESS_TEXTURE
        delete(pixel_data)
      }
    }
  }

  // Normal map
  if g_material.normal_texture.texture != nil {
    normal_handle, _ = load_gltf_texture(
      engine,
      gltf_path,
      gltf_data,
      g_material.normal_texture.texture,
    ) or_return
    features |= SHADER_FEATURE_NORMAL_TEXTURE
  }

  // TODO: Displacement map (GLTF extension, not implemented here)
  // Emissive map
  if g_material.emissive_texture.texture != nil {
    emissive_handle, _ = load_gltf_texture(
      engine,
      gltf_path,
      gltf_data,
      g_material.emissive_texture.texture,
    ) or_return
    features |= SHADER_FEATURE_EMISSIVE_TEXTURE
  }

  ret = .SUCCESS
  return
}

load_gltf_primitive :: proc(
  engine: ^Engine,
  path: string,
  gltf_data: ^cgltf.data,
  g_mesh: ^cgltf.mesh,
) -> (
  mesh_data: geometry.Geometry,
  material_handle: resource.Handle,
  ret: vk.Result,
) {
  primitives := g_mesh.primitives
  if len(primitives) == 0 {
    ret = .ERROR_UNKNOWN
    return
  }
  g_primitive := &primitives[0]
  // Material
  albedo_handle, metallic_roughness_handle, normal_handle, displacement_handle, emissive_handle, features :=
    load_gltf_pbr_textures(
      engine,
      path,
      gltf_data,
      g_primitive.material,
    ) or_return
  material_handle, _, _ = create_material(
    engine,
    features,
    albedo_handle,
    metallic_roughness_handle,
    normal_handle,
    displacement_handle,
    emissive_handle,
  )
  // Geometry
  vertices_num := g_primitive.attributes[0].data.count
  vertices := make([]geometry.Vertex, vertices_num)
  // Check for attribute count mismatches
  for &attribute in g_primitive.attributes {
    accessor := attribute.data
    if accessor.count != vertices_num {
      fmt.eprintf(
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
    }
  }
  indices: []u32
  if g_primitive.indices != nil {
    indices = make([]u32, g_primitive.indices.count)
    read := cgltf.accessor_unpack_indices(
      g_primitive.indices,
      raw_data(indices),
      size_of(u32),
      g_primitive.indices.count,
    )
    if read != g_primitive.indices.count {
      fmt.eprintf(
        "Failed to read indices from GLTF primitive. read %d, need %d\n",
        read,
        g_primitive.indices.count,
      )
      ret = .ERROR_UNKNOWN
      return
    }
  }
  mesh_data = geometry.Geometry {
    vertices = vertices,
    indices  = indices,
    aabb     = geometry.aabb_from_vertices(vertices),
  }
  return mesh_data, material_handle, .SUCCESS
}

// Helper: Prepare NodeAttachment for a skinned mesh
load_gltf_skinned_primitive :: proc(
  engine: ^Engine,
  path: string,
  gltf_data: ^cgltf.data,
  g_mesh: ^cgltf.mesh,
  g_skin: ^cgltf.skin,
) -> (
  skinned_geom_data: geometry.SkinnedGeometry,
  engine_bones: []Bone,
  mat_handle: resource.Handle,
  root_bone_idx: u32,
  node_ptr_to_bone_idx_map: map[^cgltf.node]u32,
  ret: vk.Result,
) {
  primitives := g_mesh.primitives
  if len(primitives) == 0 {
    ret = .ERROR_UNKNOWN
    return
  }
  g_primitive := &primitives[0]
  fmt.printfln("Creating texture for skinned material...")
  // Material
  albedo_handle, metallic_roughness_handle, normal_handle, displacement_handle, emissive_handle, features :=
    load_gltf_pbr_textures(
      engine,
      path,
      gltf_data,
      g_primitive.material,
    ) or_return
  mat_handle, _ = create_material(
    engine,
    features | SHADER_FEATURE_SKINNING,
    albedo_handle,
    metallic_roughness_handle,
    normal_handle,
    displacement_handle,
    emissive_handle,
  ) or_return
  fmt.printfln(
    "Creating skinned material with PBR textures %v/%v/%v/%v/%v -> %v",
    albedo_handle,
    metallic_roughness_handle,
    normal_handle,
    displacement_handle,
    emissive_handle,
    mat_handle,
  )
  // Geometry
  num_vertices := g_primitive.attributes[0].data.count
  vertices := make([]geometry.Vertex, num_vertices)
  skinnings := make([]geometry.SkinningData, num_vertices)
  attributes := g_primitive.attributes
  for attr_idx in 0 ..< len(attributes) {
    attribute := &attributes[attr_idx]
    accessor := attribute.data
    if accessor.count != num_vertices {
      fmt.eprintf(
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
    case .joints:
      // fmt.printfln("Loading joints with accessor %v", accessor)
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
            fmt.eprintf("Failed to read joints from GLTF primitive.\n")
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
  // fmt.printfln("Joints %v", vertices[len(vertices)-20:])
  indices: []u32
  if g_primitive.indices != nil {
    indices = make([]u32, g_primitive.indices.count)
    read := cgltf.accessor_unpack_indices(
      g_primitive.indices,
      raw_data(indices),
      size_of(u32),
      g_primitive.indices.count,
    )
    if read != g_primitive.indices.count {
      fmt.eprintf(
        "Failed to read indices from GLTF primitive. read %d, need %d\n",
        read,
        g_primitive.indices.count,
      )
      ret = .ERROR_UNKNOWN
      return
    }
  }
  skinned_geom_data = {
    vertices  = vertices,
    skinnings = skinnings,
    indices   = indices,
    aabb      = geometry.aabb_from_vertices(vertices),
  }
  // Bones
  engine_bones = make([]Bone, len(g_skin.joints))
  node_ptr_to_bone_idx_map = make(map[^cgltf.node]u32)
  for joint_node, i in g_skin.joints {
    node_ptr_to_bone_idx_map[joint_node] = u32(i)
    engine_bones[i].name = string(joint_node.name)
    if g_skin.inverse_bind_matrices != nil {
      ibm_floats: [16]f32
      read := cgltf.accessor_read_float(
        g_skin.inverse_bind_matrices,
        uint(i),
        raw_data(ibm_floats[:]),
        16,
      )
      if read {
        engine_bones[i].inverse_bind_matrix = geometry.matrix_from_slice(
          ibm_floats,
        )
      }
    } else {
      engine_bones[i].inverse_bind_matrix = linalg.MATRIX4F32_IDENTITY
    }
    bt := geometry.transform_identity()
    if joint_node.has_translation {
      bt.position = joint_node.translation
    }
    if joint_node.has_rotation {
      bt.rotation = quaternion(
        x = joint_node.rotation[0],
        y = joint_node.rotation[1],
        z = joint_node.rotation[2],
        w = joint_node.rotation[3],
      )
    }
    if joint_node.has_scale {
      bt.scale = joint_node.scale
    }
    engine_bones[i].bind_transform = bt
  }
  // Children indices
  for joint_node, i in g_skin.joints {
    engine_bones[i].children = make([]u32, len(joint_node.children))
    for child, j in joint_node.children {
      if idx, found := node_ptr_to_bone_idx_map[child]; found {
        engine_bones[i].children[j] = idx
      }
    }
  }
  // Root bone
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
    fmt.eprintf(
      "Warning: Could not determine unique root bone for skin, using index 0.\n",
    )
  }
  ret = .SUCCESS
  return
}


// Helper to unpack accessor data into a flat []f32. Caller must free the returned slice.
unpack_accessor_floats_flat :: proc(accessor: ^cgltf.accessor) -> []f32 {
  if accessor == nil {return nil}
  n := accessor.count * cgltf.num_components(accessor.type)
  ret := make([]f32, n)
  _ = cgltf.accessor_unpack_floats(accessor, raw_data(ret), n)
  return ret
}

load_gltf_animations :: proc(
  engine: ^Engine,
  gltf_data: ^cgltf.data,
  g_skin: ^cgltf.skin,
  engine_mesh_handle: resource.Handle,
  node_ptr_to_bone_idx_map: map[^cgltf.node]u32,
) -> bool {
  skeletal_mesh := resource.get(&engine.skeletal_meshes, engine_mesh_handle)
  skeletal_mesh.animations = make([]Animation_Clip, len(gltf_data.animations))

  for &gltf_anim, i in gltf_data.animations {
    clip := &skeletal_mesh.animations[i]
    if gltf_anim.name != nil {
      clip.name = strings.clone_from_cstring(gltf_anim.name)
    } else {
      clip.name = strings.clone(fmt.tprintf("animation_%d", i))
    }

    // Channels per bone
    fmt.printfln(
      "\nAllocating animation channels for %d bones",
      len(skeletal_mesh.bones),
    )
    clip.channels = make([]Animation_Channel, len(skeletal_mesh.bones))

    max_time: f32 = 0.0

    for gltf_channel in gltf_anim.channels {
      if gltf_channel.target_node == nil || gltf_channel.sampler == nil {
        continue
      }
      n := gltf_channel.sampler.input.count
      bone_idx, bone_found :=
        node_ptr_to_bone_idx_map[gltf_channel.target_node]
      if !bone_found {
        continue
      }
      engine_channel := &clip.channels[bone_idx]

      time_data := unpack_accessor_floats_flat(gltf_channel.sampler.input)
      // defer free(time_data)
      max_time = max(max_time, slice.max(time_data))
      fmt.printfln(
        "Bone animation %s %v: keyframe count %d",
        string(gltf_channel.target_node.name),
        gltf_channel.target_path,
        n,
      )

      switch gltf_channel.target_path {
      case .translation:
        engine_channel.position_keyframes = make([]Keyframe(Vec3), n)
        values := unpack_accessor_floats_flat(gltf_channel.sampler.output)
        // defer free(values)
        for i in 0 ..< len(time_data) {
          engine_channel.position_keyframes[i] = {
            time  = time_data[i],
            value = {values[i * 3 + 0], values[i * 3 + 1], values[i * 3 + 2]},
          }
        }
      case .rotation:
        engine_channel.rotation_keyframes = make([]Keyframe(Quat), n)
        values := unpack_accessor_floats_flat(gltf_channel.sampler.output)
        // defer free(values)
        for i in 0 ..< len(time_data) {
          engine_channel.rotation_keyframes[i] = {
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
        engine_channel.scale_keyframes = make([]Keyframe(Vec3), n)
        values := unpack_accessor_floats_flat(gltf_channel.sampler.output)
        // defer free(values)
        for i in 0 ..< len(time_data) {
          engine_channel.scale_keyframes[i] = {
            time  = time_data[i],
            value = {values[i * 3 + 0], values[i * 3 + 1], values[i * 3 + 2]},
          }
        }
      case .weights:
        fmt.printfln("Weights not handled for bone animation here")
      case .invalid:
        fmt.printfln("Invalid animation channel type")
      }
    }
    clip.duration = max_time
    // fmt.printfln("Animation %s duration: %f", clip.name, clip.duration, clip.channels)
  }
  return true
}
