package resources

import cont "../containers"
import "../gpu"
import "core:log"
import vk "vendor:vulkan"

mesh_ref :: proc(rm: ^Manager, handle: Handle) -> bool {
  mesh := cont.get(rm.meshes, handle) or_return
  mesh.ref_count += 1
  return true
}

mesh_unref :: proc(
  rm: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  mesh := cont.get(rm.meshes, handle) or_return
  if mesh.ref_count == 0 {
    // log.warnf("mesh_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  mesh.ref_count -= 1
  return mesh.ref_count, true
}

material_ref :: proc(rm: ^Manager, handle: Handle) -> bool {
  mat := cont.get(rm.materials, handle) or_return
  mat.ref_count += 1
  return true
}

material_unref :: proc(
  rm: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  mat := cont.get(rm.materials, handle) or_return
  if mat.ref_count == 0 {
    // log.warnf("material_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  mat.ref_count -= 1
  return mat.ref_count, true
}

texture_2d_ref :: proc(rm: ^Manager, handle: Handle) -> bool {
  img := cont.get(rm.images_2d, handle) or_return
  img.ref_count += 1
  return true
}

texture_2d_unref :: proc(
  rm: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  img := cont.get(rm.images_2d, handle) or_return
  if img.ref_count == 0 {
    // log.warnf("texture_2d_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  img.ref_count -= 1
  return img.ref_count, true
}

texture_cube_ref :: proc(rm: ^Manager, handle: Handle) -> bool {
  img := cont.get(rm.images_cube, handle) or_return
  img.ref_count += 1
  return true
}

texture_cube_unref :: proc(
  rm: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  img := cont.get(rm.images_cube, handle) or_return
  if img.ref_count == 0 {
    // log.warnf("texture_cube_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  img.ref_count -= 1
  return img.ref_count, true
}

purge_unused_meshes :: proc(
  rm: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  for &entry, i in rm.meshes.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      mesh, freed := cont.free(&rm.meshes, handle)
      if freed {
        mesh_destroy(mesh, rm)
        purged_count += 1
      }
    }
  }
  if purged_count > 0 {
    log.infof("Purged %d unused meshes", purged_count)
  }
  return
}

purge_unused_materials :: proc(self: ^Manager) -> (purged_count: int) {
  for &entry, i in self.materials.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      mat, freed := cont.free(&self.materials, handle)
      if freed {
        // Unref all textures referenced by this material
        texture_2d_unref(self, mat.albedo)
        texture_2d_unref(self, mat.metallic_roughness)
        texture_2d_unref(self, mat.normal)
        texture_2d_unref(self, mat.emissive)
        texture_2d_unref(self, mat.occlusion)
        purged_count += 1
      }
    }
  }
  if purged_count > 0 {
    log.infof("Purged %d unused materials", purged_count)
  }
  return
}

purge_unused_textures_2d :: proc(
  rm: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  for &entry, i in rm.images_2d.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      img, freed := cont.free(&rm.images_2d, handle)
      if freed {
        gpu.image_destroy(gctx.device, img)
        purged_count += 1
      }
    }
  }
  if purged_count > 0 {
    log.infof("Purged %d unused 2D textures", purged_count)
  }
  return
}

purge_unused_textures_cube :: proc(
  rm: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  for &entry, i in rm.images_cube.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      img, freed := cont.free(&rm.images_cube, handle)
      if freed {
        gpu.cube_depth_texture_destroy(gctx.device, img)
        purged_count += 1
      }
    }
  }
  if purged_count > 0 {
    log.infof("Purged %d unused cube textures", purged_count)
  }
  return
}

purge_unused_resources :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  total_purged: int,
) {
  // TODO: purging procedure is now running a full scan O(n) over all resources, which is expensive. we need to optimize this
  total_purged += purge_unused_meshes(self, gctx)
  total_purged += purge_unused_materials(self)
  total_purged += purge_unused_textures_2d(self, gctx)
  total_purged += purge_unused_textures_cube(self, gctx)
  if total_purged > 0 {
    log.infof("Total resources purged: %d", total_purged)
  }
  return
}
