package gltf_render

import render ".."
import "../mesh"
import "core:log"
import "core:mem"
import "core:os"
import path "core:path/filepath"
import "core:slice"
import "vendor:cgltf"
import vk "vendor:vulkan"

// load_meshes creates a render mesh, material and textures for every glTF mesh a node references.
// looks[i] draws data.meshes[i]; it is nil for meshes no node uses or that failed to upload.
// Meshes used by a skinned node carry skinning data. gltf_path resolves relative texture URIs.
load_meshes :: proc(
  r: ^render.Renderer,
  data: ^cgltf.data,
  gltf_path: string,
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
  for &gltf_mesh, i in data.meshes do if used[i] {
    if len(gltf_mesh.primitives) == 0 do return looks, false
    // One material per mesh: the first primitive's.
    material: render.MaterialHandle
    if mat := gltf_mesh.primitives[0].material; mat != nil {
      material = load_material(r, mat, gltf_path, &textures, &materials) or_return
    }
    geometry := load_geometry(&gltf_mesh, skinned[i])
    log.infof("Processed mesh with %d vertices, %d indices", len(geometry.vertices), len(geometry.indices))
    handle := render.create_mesh(r, geometry) or_continue
    looks[i] = render.MeshAttachment{handle = handle, material = material, cast_shadow = true}
  }
  log.infof("glTF looks: %d textures, %d materials", len(textures), len(materials))
  return looks, true
}

@(private = "file")
load_texture :: proc(
  r: ^render.Renderer,
  texture: ^cgltf.texture,
  gltf_path: string,
  cache: ^map[^cgltf.texture]render.TextureHandle,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: render.TextureHandle,
  ok: bool,
) {
  if handle, ok = cache[texture]; ok do return
  if texture.image_ == nil do return {}, false
  pixel_data: []u8
  if texture.image_.uri != nil {
    texture_path, jerr := path.join({path.dir(gltf_path), string(texture.image_.uri)}, context.temp_allocator)
    if jerr != nil do return {}, false
    err: os.Error
    pixel_data, err = os.read_entire_file(texture_path, context.allocator)
    if err != nil do return {}, false
  } else if texture.image_.buffer_view != nil {
    view := texture.image_.buffer_view
    pixel_data = slice.clone(slice.from_ptr(mem.ptr_offset(cast(^u8)view.buffer.data, view.offset), int(view.size)))
  } else {
    return {}, false
  }
  defer delete(pixel_data)
  res: vk.Result
  handle, res = render.create_texture_from_data(r, pixel_data, format)
  if res != .SUCCESS do return {}, false
  cache[texture] = handle
  log.infof("Created texture %v", handle)
  return handle, true
}

@(private = "file")
load_material :: proc(
  r: ^render.Renderer,
  mat: ^cgltf.material,
  gltf_path: string,
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
    format:  vk.Format,
  } {
    {mat.pbr_metallic_roughness.base_color_texture.texture, .R8G8B8A8_SRGB},
    {mat.pbr_metallic_roughness.metallic_roughness_texture.texture, .R8G8B8A8_UNORM},
    {mat.normal_texture.texture, .R8G8B8A8_UNORM},
    {mat.emissive_texture.texture, .R8G8B8A8_SRGB},
  }
  tex: [4]render.TextureHandle
  for src, i in sources do if src.texture != nil {
    tex[i] = load_texture(r, src.texture, gltf_path, textures, src.format) or_return
  }
  // render keeps one emissive scale; take the brightest factor channel
  emissive_value := max(mat.emissive_factor[0], mat.emissive_factor[1], mat.emissive_factor[2])
  if mat.has_emissive_strength do emissive_value *= mat.emissive_strength.emissive_strength
  handle = render.create_material(
    r,
    .PBR,
    tex[0],
    tex[1],
    tex[2],
    tex[3],
    metallic_value = metallic,
    roughness_value = roughness,
    emissive_value = emissive_value,
    base_color_factor = base_color,
  ) or_return
  cache[mat] = handle
  log.infof("Created material %v", handle)
  return handle, true
}

@(private = "file")
load_geometry :: proc(gltf_mesh: ^cgltf.mesh, include_skinning: bool) -> mesh.Geometry {
  vertices := make([dynamic]mesh.Vertex, 0, context.allocator)
  indices := make([dynamic]u32, 0, context.allocator)
  skinnings: [dynamic]mesh.SkinningData
  if include_skinning do skinnings = make([dynamic]mesh.SkinningData, 0, context.allocator)
  for &prim in gltf_mesh.primitives {
    vertex_offset := u32(len(vertices))
    count := int(prim.attributes[0].data.count)
    resize(&vertices, len(vertices) + count)
    prim_skinnings: []mesh.SkinningData
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
  return mesh.make_geometry(vertices[:], indices[:], skinnings[:])
}

@(private = "file")
load_vertex_attributes :: proc(
  primitive: ^cgltf.primitive,
  vertices: []mesh.Vertex,
  skinnings: []mesh.SkinningData = nil,
) {
  // glTF vertex color is optional and multiplies base_color_factor
  for &v in vertices do v.color = {1, 1, 1, 1}
  for attribute in primitive.attributes {
    accessor := attribute.data
    #partial switch attribute.type {
    case .position:
      read_floats(accessor, vertices, offset_of(mesh.Vertex, position), 3)
    case .normal:
      read_floats(accessor, vertices, offset_of(mesh.Vertex, normal), 3)
    case .texcoord:
      if attribute.index == 0 do read_floats(accessor, vertices, offset_of(mesh.Vertex, uv), 2)
    case .color:
      if attribute.index == 0 do read_floats(accessor, vertices, offset_of(mesh.Vertex, color), 4)
    case .tangent:
      read_floats(accessor, vertices, offset_of(mesh.Vertex, tangent), 4)
    case .joints:
      if attribute.index == 0 && skinnings != nil {
        for i in 0 ..< min(int(accessor.count), len(skinnings)) {
          cgltf.accessor_read_uint(accessor, uint(i), raw_data(skinnings[i].joints[:]), len(skinnings[i].joints)) or_continue
        }
      }
    case .weights:
      if attribute.index == 0 do read_floats(accessor, skinnings, offset_of(mesh.SkinningData, weights), 4)
    }
  }
}

@(private = "file")
read_floats :: proc(accessor: ^cgltf.accessor, items: []$T, offset: uintptr, n: uint) {
  for i in 0 ..< min(int(accessor.count), len(items)) {
    _ = cgltf.accessor_read_float(accessor, uint(i), ([^]f32)(uintptr(&items[i]) + offset), n)
  }
}
