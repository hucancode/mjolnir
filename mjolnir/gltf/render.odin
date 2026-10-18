package gltf

import "../render"
import "core:log"
import "core:mem"
import "core:slice"
import "vendor:cgltf"

// load_meshes creates a render mesh, material and textures for every glTF mesh a node references,
// and records them in model. looks[i] draws data.meshes[i]; it is nil for meshes no node uses or
// that failed to upload. Meshes used by a skinned node carry skinning data. Images must be
// embedded (a .glb's buffer views): render reads no files.
@(private)
load_meshes :: proc(
  r: ^render.Renderer,
  data: ^cgltf.data,
  model: ^Model,
  allocator := context.allocator,
) -> (
  looks: []Maybe(render.MeshAttachment),
  ok: bool,
) {
  looks = make([]Maybe(render.MeshAttachment), len(data.meshes), allocator)
  used := make([]bool, len(data.meshes), context.temp_allocator)
  skinned := make([]bool, len(data.meshes), context.temp_allocator)
  for &node in data.nodes do if node.mesh != nil {
    i := cgltf.mesh_index(data, node.mesh)
    used[i] = true
    if node.skin != nil do skinned[i] = true
  }
  textures := make(map[^cgltf.texture]render.TextureHandle, context.temp_allocator)
  materials := make(map[^cgltf.material]render.MaterialHandle, context.temp_allocator)
  defer {
    for _, t in textures do append(&model.textures, t)
    for _, m in materials do append(&model.materials, m)
  }
  for &gltf_mesh, i in data.meshes do if used[i] {
    if len(gltf_mesh.primitives) == 0 do return looks, false
    // One material per mesh: the first primitive's, or plain white when it has none
    // (material 0 means "none" and is never drawn).
    material := r.builtin_materials[.WHITE]
    if mat := gltf_mesh.primitives[0].material; mat != nil {
      material = load_material(r, mat, &textures, &materials) or_return
    }
    geometry := load_geometry(&gltf_mesh, skinned[i])
    log.infof("Processed mesh with %d vertices, %d indices", len(geometry.vertices), len(geometry.indices))
    handle := render.mesh_create(r, geometry) or_continue
    append(&model.meshes, handle)
    looks[i] = render.MeshAttachment{mesh = handle, material = material, cast_shadow = true}
  }
  log.infof("glTF looks: %d textures, %d materials", len(textures), len(materials))
  return looks, true
}

@(private = "file")
load_texture :: proc(
  r: ^render.Renderer,
  texture: ^cgltf.texture,
  cache: ^map[^cgltf.texture]render.TextureHandle,
  format: render.TextureFormat = .RGBA8_SRGB,
) -> (
  handle: render.TextureHandle,
  ok: bool,
) {
  if handle, ok = cache[texture]; ok do return
  if texture.image_ == nil || texture.image_.buffer_view == nil {
    log.errorf("glTF texture: external images are unsupported, embed them (.glb)")
    return {}, false
  }
  view := texture.image_.buffer_view
  pixel_data := slice.from_ptr(mem.ptr_offset(cast(^u8)view.buffer.data, view.offset), int(view.size))
  handle = render.texture_create(r, pixel_data, format) or_return
  cache[texture] = handle
  log.infof("Created texture %v", handle)
  return handle, true
}

@(private = "file")
load_material :: proc(
  r: ^render.Renderer,
  mat: ^cgltf.material,
  textures: ^map[^cgltf.texture]render.TextureHandle,
  cache: ^map[^cgltf.material]render.MaterialHandle,
) -> (
  handle: render.MaterialHandle,
  ok: bool,
) {
  if handle, ok = cache[mat]; ok do return
  base_color := [4]f32{1, 1, 1, 1}
  metallic, roughness: f32 = 0, 1
  if mat.has_pbr_metallic_roughness {
    base_color = mat.pbr_metallic_roughness.base_color_factor
    metallic = mat.pbr_metallic_roughness.metallic_factor
    roughness = mat.pbr_metallic_roughness.roughness_factor
  }
  // albedo, metallic-roughness, normal, emissive; color data is sRGB
  sources := [4]struct {
    texture: ^cgltf.texture,
    format:  render.TextureFormat,
  } {
    {mat.pbr_metallic_roughness.base_color_texture.texture, .RGBA8_SRGB},
    {mat.pbr_metallic_roughness.metallic_roughness_texture.texture, .RGBA8_UNORM},
    {mat.normal_texture.texture, .RGBA8_UNORM},
    {mat.emissive_texture.texture, .RGBA8_SRGB},
  }
  tex: [4]render.TextureHandle
  for src, i in sources do if src.texture != nil {
    tex[i] = load_texture(r, src.texture, textures, src.format) or_return
  }
  // render keeps one emissive scale; take the brightest factor channel
  emissive_value := max(mat.emissive_factor[0], mat.emissive_factor[1], mat.emissive_factor[2])
  if mat.has_emissive_strength do emissive_value *= mat.emissive_strength.emissive_strength
  handle = render.material_create(
    r,
    render.make_material(
      .PBR,
      tex[0],
      tex[1],
      tex[2],
      tex[3],
      metallic_value = metallic,
      roughness_value = roughness,
      emissive_value = emissive_value,
      base_color_factor = base_color,
    ),
  ) or_return
  cache[mat] = handle
  log.infof("Created material %v", handle)
  return handle, true
}

@(private = "file")
load_geometry :: proc(gltf_mesh: ^cgltf.mesh, include_skinning: bool) -> render.Geometry {
  vertices := make([dynamic]render.Vertex, 0, context.allocator)
  indices := make([dynamic]u32, 0, context.allocator)
  skinnings: [dynamic]render.SkinningData
  if include_skinning do skinnings = make([dynamic]render.SkinningData, 0, context.allocator)
  for &prim in gltf_mesh.primitives {
    vertex_offset := u32(len(vertices))
    count := int(prim.attributes[0].data.count)
    resize(&vertices, len(vertices) + count)
    prim_skinnings: []render.SkinningData
    if include_skinning {
      resize(&skinnings, len(skinnings) + count)
      prim_skinnings = skinnings[len(skinnings) - count:]
    }
    load_vertex_attributes(&prim, vertices[len(vertices) - count:], prim_skinnings)
    if prim.indices != nil {
      first := len(indices)
      resize(&indices, first + int(prim.indices.count))
      _ = cgltf.accessor_unpack_indices(prim.indices, raw_data(indices[first:]), size_of(u32), prim.indices.count)
      for &index in indices[first:] do index += vertex_offset
    } else {
      for i in 0 ..< count do append(&indices, vertex_offset + u32(i))
    }
  }
  // nil skinnings without include_skinning
  return render.make_geometry(vertices[:], indices[:], skinnings[:])
}

@(private = "file")
load_vertex_attributes :: proc(
  primitive: ^cgltf.primitive,
  vertices: []render.Vertex,
  skinnings: []render.SkinningData = nil,
) {
  // glTF vertex color is optional and multiplies base_color_factor
  for &v in vertices do v.color = {1, 1, 1, 1}
  for attribute in primitive.attributes {
    accessor := attribute.data
    #partial switch attribute.type {
    case .position:
      read_floats(accessor, vertices, offset_of(render.Vertex, position), 3)
    case .normal:
      read_floats(accessor, vertices, offset_of(render.Vertex, normal), 3)
    case .texcoord:
      if attribute.index == 0 do read_floats(accessor, vertices, offset_of(render.Vertex, uv), 2)
    case .color:
      if attribute.index == 0 do read_floats(accessor, vertices, offset_of(render.Vertex, color), 4)
    case .tangent:
      read_floats(accessor, vertices, offset_of(render.Vertex, tangent), 4)
    case .joints:
      if attribute.index == 0 && skinnings != nil {
        for i in 0 ..< min(int(accessor.count), len(skinnings)) {
          cgltf.accessor_read_uint(accessor, uint(i), raw_data(skinnings[i].joints[:]), len(skinnings[i].joints)) or_continue
        }
      }
    case .weights:
      if attribute.index == 0 do read_floats(accessor, skinnings, offset_of(render.SkinningData, weights), 4)
    }
  }
}

@(private = "file")
read_floats :: proc(accessor: ^cgltf.accessor, items: []$T, offset: uintptr, n: uint) {
  for i in 0 ..< min(int(accessor.count), len(items)) {
    _ = cgltf.accessor_read_float(accessor, uint(i), ([^]f32)(uintptr(&items[i]) + offset), n)
  }
}
