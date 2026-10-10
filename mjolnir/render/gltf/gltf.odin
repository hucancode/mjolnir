// glTF mesh, material and texture import into render resources.
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

// Create a render mesh, material and textures for every glTF mesh a node
// references. looks[i] draws data.meshes[i]; it is nil for meshes no node
// uses or that failed to upload. Meshes used by a skinned node carry
// skinning data. `gltf_path` resolves relative texture URIs.
load_meshes :: proc(
  r: ^render.Manager,
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
  textures := make(map[^cgltf.texture]render.Texture2DHandle, context.temp_allocator)
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
    handle := render.create_mesh(r, geometry, true) or_continue
    looks[i] = render.MeshAttachment{handle = handle, material = material, cast_shadow = true}
  }
  log.infof("glTF looks: %d textures, %d materials", len(textures), len(materials))
  return looks, true
}

@(private = "file")
load_texture :: proc(
  r: ^render.Manager,
  texture: ^cgltf.texture,
  gltf_path: string,
  cache: ^map[^cgltf.texture]render.Texture2DHandle,
) -> (
  handle: render.Texture2DHandle,
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
  handle, res = render.create_texture_from_data(r, pixel_data, .R8G8B8A8_UNORM)
  if res != .SUCCESS do return {}, false
  cache[texture] = handle
  log.infof("Created texture %v", handle)
  return handle, true
}

@(private = "file")
load_material :: proc(
  r: ^render.Manager,
  mat: ^cgltf.material,
  gltf_path: string,
  textures: ^map[^cgltf.texture]render.Texture2DHandle,
  cache: ^map[^cgltf.material]render.MaterialHandle,
) -> (
  handle: render.MaterialHandle,
  ok: bool,
) {
  if handle, ok = cache[mat]; ok do return
  albedo, metallic_roughness, normal, emissive, occlusion: render.Texture2DHandle
  features: render.ShaderFeatureSet
  if mat.has_pbr_metallic_roughness {
    if tex := mat.pbr_metallic_roughness.metallic_roughness_texture.texture; tex != nil {
      metallic_roughness = load_texture(r, tex, gltf_path, textures) or_return
      features |= {.METALLIC_ROUGHNESS_TEXTURE}
    }
  }
  if tex := mat.pbr_metallic_roughness.base_color_texture.texture; tex != nil {
    albedo = load_texture(r, tex, gltf_path, textures) or_return
    features |= {.ALBEDO_TEXTURE}
  }
  if tex := mat.normal_texture.texture; tex != nil {
    normal = load_texture(r, tex, gltf_path, textures) or_return
    features |= {.NORMAL_TEXTURE}
  }
  if tex := mat.emissive_texture.texture; tex != nil {
    emissive = load_texture(r, tex, gltf_path, textures) or_return
    features |= {.EMISSIVE_TEXTURE}
  }
  if tex := mat.occlusion_texture.texture; tex != nil {
    occlusion = load_texture(r, tex, gltf_path, textures) or_return
    features |= {.OCCLUSION_TEXTURE}
  }
  handle = render.create_material(r, features, .PBR, albedo, metallic_roughness, normal, emissive, occlusion) or_return
  cache[mat] = handle
  log.infof("Created material %v", handle)
  return handle, true
}

// All primitives of a glTF mesh merged into one geometry.
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
  if include_skinning do return mesh.make_geometry(vertices[:], indices[:], skinnings[:])
  return mesh.make_geometry(vertices[:], indices[:])
}

@(private = "file")
load_vertex_attributes :: proc(
  primitive: ^cgltf.primitive,
  vertices: []mesh.Vertex,
  skinnings: []mesh.SkinningData = nil,
) {
  for attribute in primitive.attributes {
    accessor := attribute.data
    #partial switch attribute.type {
    case .position:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        cgltf.accessor_read_float(accessor, uint(i), raw_data(vertices[i].position[:]), 3) or_continue
      }
    case .normal:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        cgltf.accessor_read_float(accessor, uint(i), raw_data(vertices[i].normal[:]), 3) or_continue
      }
    case .texcoord:
      if attribute.index == 0 {
        for i in 0 ..< min(int(accessor.count), len(vertices)) {
          cgltf.accessor_read_float(accessor, uint(i), raw_data(vertices[i].uv[:]), 2) or_continue
        }
      }
    case .tangent:
      for i in 0 ..< min(int(accessor.count), len(vertices)) {
        cgltf.accessor_read_float(accessor, uint(i), raw_data(vertices[i].tangent[:]), 4) or_continue
      }
    case .joints:
      if attribute.index == 0 && skinnings != nil {
        for i in 0 ..< min(int(accessor.count), len(skinnings)) {
          cgltf.accessor_read_uint(accessor, uint(i), raw_data(skinnings[i].joints[:]), len(skinnings[i].joints)) or_continue
        }
      }
    case .weights:
      if attribute.index == 0 && skinnings != nil {
        for i in 0 ..< min(int(accessor.count), len(skinnings)) {
          cgltf.accessor_read_float(accessor, uint(i), raw_data(skinnings[i].weights[:]), 4) or_continue
        }
      }
    }
  }
}
