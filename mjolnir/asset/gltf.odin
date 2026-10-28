package asset

import "../geometry"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "vendor:cgltf"

// load_gltf reads a glTF held in memory: a .glb, or a glTF whose buffers and images are all
// embedded (it reads no files). Meshes no node uses stay empty. Free with model_destroy.
load_gltf :: proc(bytes: []u8) -> (model: Model, ok: bool) #optional_ok {
  options: cgltf.options
  data, result := cgltf.parse(options, raw_data(bytes), uint(len(bytes)))
  if result != .success {
    log.errorf("Failed to parse glTF: %v", result)
    return {}, false
  }
  defer cgltf.free(data)
  // no gltf path: a .glb's BIN chunk and data: URIs load, a buffer in another file fails
  if len(data.buffers) > 0 {
    if result = cgltf.load_buffers(options, data, nil); result != .success {
      log.errorf("Failed to load glTF buffers: %v", result)
      return {}, false
    }
  }
  node_order := read_nodes(data, &model)
  read_meshes(data, &model)
  read_materials(data, &model)
  read_skins(data, node_order, &model)
  read_clips(data, node_order, &model)
  read_lights(data, &model)
  return model, true
}

// The nodes, parents first; returns where each glTF node went.
@(private = "file")
read_nodes :: proc(data: ^cgltf.data, model: ^Model) -> []int {
  order := make([]int, len(data.nodes), context.temp_allocator)
  nodes := make([dynamic]Node, 0, len(data.nodes))
  Entry :: struct {
    node, parent: int,
  }
  stack := make([dynamic]Entry, context.temp_allocator)
  #reverse for &node, i in data.nodes do if node.parent == nil do append(&stack, Entry{i, -1})
  for len(stack) > 0 {
    e := pop(&stack)
    src := &data.nodes[e.node]
    n := Node{name = strings.clone(string(src.name)), parent = e.parent, mesh = -1, skin = -1, light = -1}
    if src.has_matrix {
      n.transform.position, n.transform.rotation, n.transform.scale = geometry.decompose_matrix(transmute(matrix[4, 4]f32)src.matrix_)
    } else {
      // cgltf fills absent components with identity values
      n.transform = {src.translation, transmute(quaternion128)src.rotation, src.scale}
    }
    if src.mesh != nil do n.mesh = int(cgltf.mesh_index(data, src.mesh))
    if src.skin != nil do n.skin = int(cgltf.skin_index(data, src.skin))
    if src.light != nil do n.light = int(cgltf.light_index(data, src.light))
    order[e.node] = len(nodes)
    append(&nodes, n)
    #reverse for child in src.children do append(&stack, Entry{int(cgltf.node_index(data, child)), order[e.node]})
  }
  model.nodes = nodes[:]
  return order
}

@(private = "file")
read_meshes :: proc(data: ^cgltf.data, model: ^Model) {
  used := make([]bool, len(data.meshes), context.temp_allocator)
  skinned := make([]bool, len(data.meshes), context.temp_allocator)
  for n in model.nodes do if n.mesh >= 0 {
    used[n.mesh] = true
    if n.skin >= 0 do skinned[n.mesh] = true
  }
  model.meshes = make([][]Primitive, len(data.meshes))
  for &src, i in data.meshes do if used[i] {
    prims := make([dynamic]Primitive, 0, len(src.primitives))
    for &prim in src.primitives do if len(prim.attributes) > 0 {
      material := int(cgltf.material_index(data, prim.material)) if prim.material != nil else -1
      append(&prims, Primitive{read_primitive(&prim, skinned[i]), material})
    }
    model.meshes[i] = prims[:]
  }
}

@(private = "file")
read_primitive :: proc(prim: ^cgltf.primitive, skinned: bool) -> geometry.Mesh {
  count := int(prim.attributes[0].data.count)
  vertices := make([]geometry.Vertex, count)
  skinnings: []geometry.SkinningData
  if skinned do skinnings = make([]geometry.SkinningData, count)
  // glTF vertex color is optional and multiplies base_color
  for &v in vertices do v.color = {1, 1, 1, 1}
  for attribute in prim.attributes {
    accessor := attribute.data
    #partial switch attribute.type {
    case .position:
      read_floats(accessor, vertices, offset_of(geometry.Vertex, position), 3)
    case .normal:
      read_floats(accessor, vertices, offset_of(geometry.Vertex, normal), 3)
    case .texcoord:
      if attribute.index == 0 do read_floats(accessor, vertices, offset_of(geometry.Vertex, uv), 2)
    case .color:
      if attribute.index == 0 do read_floats(accessor, vertices, offset_of(geometry.Vertex, color), 4)
    case .tangent:
      read_floats(accessor, vertices, offset_of(geometry.Vertex, tangent), 4)
    case .joints:
      if attribute.index == 0 && skinned {
        for i in 0 ..< min(int(accessor.count), count) {
          cgltf.accessor_read_uint(accessor, uint(i), raw_data(skinnings[i].joints[:]), len(skinnings[i].joints)) or_continue
        }
      }
    case .weights:
      if attribute.index == 0 do read_floats(accessor, skinnings, offset_of(geometry.SkinningData, weights), 4)
    }
  }
  indices: []u32
  if prim.indices != nil {
    indices = make([]u32, int(prim.indices.count))
    _ = cgltf.accessor_unpack_indices(prim.indices, raw_data(indices), size_of(u32), prim.indices.count)
  } else {
    indices = make([]u32, count)
    for i in 0 ..< count do indices[i] = u32(i)
  }
  return geometry.make_mesh(vertices, indices, skinnings)
}

@(private = "file")
read_floats :: proc(accessor: ^cgltf.accessor, items: []$T, offset: uintptr, n: uint) {
  for i in 0 ..< min(int(accessor.count), len(items)) {
    _ = cgltf.accessor_read_float(accessor, uint(i), ([^]f32)(uintptr(&items[i]) + offset), n)
  }
}

@(private = "file")
read_materials :: proc(data: ^cgltf.data, model: ^Model) {
  model.images = make([][]u8, len(data.images))
  for &img, i in data.images {
    if img.buffer_view == nil {
      log.errorf("glTF image %d: external images are unsupported, embed them (.glb)", i)
      continue
    }
    view := img.buffer_view
    model.images[i] = slice.clone(slice.from_ptr(mem.ptr_offset(cast(^u8)view.buffer.data, view.offset), int(view.size)))
  }
  model.materials = make([]Material, len(data.materials))
  for &src, i in data.materials {
    m := &model.materials[i]
    m^ = {base_color = {1, 1, 1, 1}, roughness = 1, textures = {.ALBEDO = -1, .METALLIC_ROUGHNESS = -1, .NORMAL = -1, .EMISSIVE = -1}}
    if src.has_pbr_metallic_roughness {
      m.base_color = src.pbr_metallic_roughness.base_color_factor
      m.metallic = src.pbr_metallic_roughness.metallic_factor
      m.roughness = src.pbr_metallic_roughness.roughness_factor
    }
    m.emissive = max(src.emissive_factor[0], src.emissive_factor[1], src.emissive_factor[2])
    if src.has_emissive_strength do m.emissive *= src.emissive_strength.emissive_strength
    textures := [TextureSlot]^cgltf.texture {
      .ALBEDO             = src.pbr_metallic_roughness.base_color_texture.texture,
      .METALLIC_ROUGHNESS = src.pbr_metallic_roughness.metallic_roughness_texture.texture,
      .NORMAL             = src.normal_texture.texture,
      .EMISSIVE           = src.emissive_texture.texture,
    }
    for t, slot in textures do if t != nil && t.image_ != nil do m.textures[slot] = int(cgltf.image_index(data, t.image_))
  }
}

@(private = "file")
read_skins :: proc(data: ^cgltf.data, order: []int, model: ^Model) {
  model.skins = make([]Skin, len(data.skins))
  for &src, i in data.skins {
    n := len(src.joints)
    s := &model.skins[i]
    s.name = strings.clone(string(src.name))
    s.joints = make([]int, n)
    s.parents = make([]i32, n)
    s.inverse_bind = make([]matrix[4, 4]f32, n)
    s.rest = make([]geometry.Transform, n)
    for joint, j in src.joints {
      s.joints[j] = order[cgltf.node_index(data, joint)]
      s.parents[j] = -1
      if p, found := slice.linear_search(src.joints, joint.parent); found do s.parents[j] = i32(p)
      s.inverse_bind[j] = 1
      if src.inverse_bind_matrices != nil {
        if !cgltf.accessor_read_float(src.inverse_bind_matrices, uint(j), auto_cast &s.inverse_bind[j], 16) {
          log.warnf("glTF skin %d: no inverse bind matrix for joint %d", i, j)
        }
      }
      s.rest[j] = model.nodes[s.joints[j]].transform
    }
  }
}

@(private = "file")
read_clips :: proc(data: ^cgltf.data, order: []int, model: ^Model) {
  model.clips = make([]Clip, len(data.animations))
  for &src, i in data.animations {
    c := &model.clips[i]
    c.name = strings.clone(string(src.name)) if src.name != nil else fmt.aprintf("animation_%d", i)
    channels := make([dynamic]Channel, 0, len(src.channels))
    for &ch in src.channels do if ch.target_node != nil && ch.sampler != nil {
      out := Channel{node = order[cgltf.node_index(data, ch.target_node)]}
      #partial switch ch.target_path {
      case .translation:
        out.path = .TRANSLATION
      case .rotation:
        out.path = .ROTATION
      case .scale:
        out.path = .SCALE
      case:
        continue
      }
      switch ch.sampler.interpolation {
      case .linear:
        out.interpolation = .LINEAR
      case .step:
        out.interpolation = .STEP
      case .cubic_spline:
        out.interpolation = .CUBIC
      }
      out.times = make([]f32, ch.sampler.input.count)
      _ = cgltf.accessor_unpack_floats(ch.sampler.input, raw_data(out.times), uint(len(out.times)))
      out.values = make([]f32, cgltf.accessor_unpack_floats(ch.sampler.output, nil, 0))
      _ = cgltf.accessor_unpack_floats(ch.sampler.output, raw_data(out.values), uint(len(out.values)))
      append(&channels, out)
    }
    c.channels = channels[:]
  }
}

@(private = "file")
read_lights :: proc(data: ^cgltf.data, model: ^Model) {
  model.lights = make([]Light, len(data.lights))
  for &src, i in data.lights {
    l := &model.lights[i]
    l^ = {color = src.color, intensity = src.intensity, range = src.range, inner_angle = src.spot_inner_cone_angle, outer_angle = src.spot_outer_cone_angle}
    #partial switch src.type {
    case .directional:
      l.type = .DIRECTIONAL
    case .point:
      l.type = .POINT
    case .spot:
      l.type = .SPOT
    }
  }
}
