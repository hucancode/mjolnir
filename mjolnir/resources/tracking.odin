package resources

import cont "../containers"
import "../gpu"
import "core:log"
import vk "vendor:vulkan"

mesh_ref :: proc(manager: ^Manager, handle: Handle) -> bool {
  mesh := cont.get(manager.meshes, handle) or_return
  mesh.ref_count += 1
  return true
}

mesh_unref :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  mesh := cont.get(manager.meshes, handle) or_return
  if mesh.ref_count == 0 {
    // log.warnf("mesh_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  mesh.ref_count -= 1
  return mesh.ref_count, true
}

material_ref :: proc(manager: ^Manager, handle: Handle) -> bool {
  mat := cont.get(manager.materials, handle) or_return
  mat.ref_count += 1
  return true
}

material_unref :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  mat := cont.get(manager.materials, handle) or_return
  if mat.ref_count == 0 {
    // log.warnf("material_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  mat.ref_count -= 1
  return mat.ref_count, true
}

texture_2d_ref :: proc(manager: ^Manager, handle: Handle) -> bool {
  img := cont.get(manager.image_2d_buffers, handle) or_return
  img.ref_count += 1
  return true
}

texture_2d_unref :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  img := cont.get(manager.image_2d_buffers, handle) or_return
  if img.ref_count == 0 {
    // log.warnf("texture_2d_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  img.ref_count -= 1
  return img.ref_count, true
}

texture_cube_ref :: proc(manager: ^Manager, handle: Handle) -> bool {
  img := cont.get(manager.image_cube_buffers, handle) or_return
  img.ref_count += 1
  return true
}

texture_cube_unref :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ref_count: u32,
  ok: bool,
) {
  img := cont.get(manager.image_cube_buffers, handle) or_return
  if img.ref_count == 0 {
    // log.warnf("texture_cube_unref: ref_count already 0 for handle %v", handle)
    return 0, true
  }
  img.ref_count -= 1
  return img.ref_count, true
}

purge_unused_meshes :: proc(
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  for &entry, i in manager.meshes.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      mesh, freed := cont.free(&manager.meshes, handle)
      if freed {
        mesh_destroy(mesh, gctx, manager)
        purged_count += 1
      }
    }
  }
  if purged_count > 0 {
    log.infof("Purged %d unused meshes", purged_count)
  }
  return
}

purge_unused_materials :: proc(manager: ^Manager) -> (purged_count: int) {
  for &entry, i in manager.materials.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      mat, freed := cont.free(&manager.materials, handle)
      if freed {
        // Unref all textures referenced by this material
        texture_2d_unref(manager, mat.albedo)
        texture_2d_unref(manager, mat.metallic_roughness)
        texture_2d_unref(manager, mat.normal)
        texture_2d_unref(manager, mat.emissive)
        texture_2d_unref(manager, mat.occlusion)
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
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  for &entry, i in manager.image_2d_buffers.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      img, freed := cont.free(&manager.image_2d_buffers, handle)
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
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  for &entry, i in manager.image_cube_buffers.entries do if entry.active {
    if entry.item.auto_purge && entry.item.ref_count == 0 {
      handle := Handle {
        index      = u32(i),
        generation = entry.generation,
      }
      img, freed := cont.free(&manager.image_cube_buffers, handle)
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
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  total_purged: int,
) {
  // TODO: purging procedure is now running a full scan O(n) over all resources, which is expensive. we need to optimize this
  total_purged += purge_unused_meshes(manager, gctx)
  total_purged += purge_unused_materials(manager)
  total_purged += purge_unused_textures_2d(manager, gctx)
  total_purged += purge_unused_textures_cube(manager, gctx)
  if total_purged > 0 {
    log.infof("Total resources purged: %d", total_purged)
  }
  return
}
