package world

import d "../data"
import "core:sync"

StagingEntry :: struct($T: typeid) {
  data: T,
  n:    u32,
}

StagingList :: struct {
  transforms: map[d.NodeHandle]StagingEntry(matrix[4, 4]f32),
  node_data:  map[d.NodeHandle]StagingEntry(d.NodeData),
  mesh_updates: map[d.MeshHandle]StagingEntry(d.MeshData),
  material_updates: map[d.MaterialHandle]StagingEntry(d.MaterialData),
  bone_updates: map[d.NodeHandle]StagingEntry([dynamic]matrix[4, 4]f32),
  sprite_updates: map[d.SpriteHandle]StagingEntry(d.SpriteData),
  emitter_updates: map[d.EmitterHandle]StagingEntry(d.EmitterData),
  forcefield_updates: map[d.ForceFieldHandle]StagingEntry(d.ForceFieldData),
  light_updates: map[d.LightHandle]StagingEntry(d.LightData),
  mutex: sync.Mutex,
}

staging_init :: proc(staging: ^StagingList) {
  staging.transforms = make(map[d.NodeHandle]StagingEntry(matrix[4, 4]f32))
  staging.node_data = make(map[d.NodeHandle]StagingEntry(d.NodeData))
  staging.mesh_updates = make(map[d.MeshHandle]StagingEntry(d.MeshData))
  staging.material_updates = make(map[d.MaterialHandle]StagingEntry(d.MaterialData))
  staging.bone_updates = make(map[d.NodeHandle]StagingEntry([dynamic]matrix[4, 4]f32))
  staging.sprite_updates = make(map[d.SpriteHandle]StagingEntry(d.SpriteData))
  staging.emitter_updates = make(map[d.EmitterHandle]StagingEntry(d.EmitterData))
  staging.forcefield_updates = make(map[d.ForceFieldHandle]StagingEntry(d.ForceFieldData))
  staging.light_updates = make(map[d.LightHandle]StagingEntry(d.LightData))
}

staging_destroy :: proc(staging: ^StagingList) {
  for _, entry in staging.bone_updates {
    delete(entry.data)
  }
  delete(staging.transforms)
  delete(staging.node_data)
  delete(staging.mesh_updates)
  delete(staging.material_updates)
  delete(staging.bone_updates)
  delete(staging.sprite_updates)
  delete(staging.emitter_updates)
  delete(staging.forcefield_updates)
  delete(staging.light_updates)
}

stage_node_transform :: proc(
  staging: ^StagingList,
  handle: d.NodeHandle,
  world_matrix: matrix[4, 4]f32,
) {
  sync.mutex_lock(&staging.mutex)
  staging.transforms[handle] = {
    data = world_matrix,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_node_data :: proc(
  staging: ^StagingList,
  handle: d.NodeHandle,
  node_data: d.NodeData,
) {
  sync.mutex_lock(&staging.mutex)
  staging.node_data[handle] = {
    data = node_data,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_mesh_data :: proc(
  staging: ^StagingList,
  handle: d.MeshHandle,
  mesh_data: d.MeshData,
) {
  sync.mutex_lock(&staging.mutex)
  staging.mesh_updates[handle] = {
    data = mesh_data,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_material_data :: proc(
  staging: ^StagingList,
  handle: d.MaterialHandle,
  material_data: d.MaterialData,
) {
  sync.mutex_lock(&staging.mutex)
  staging.material_updates[handle] = {
    data = material_data,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_bone_matrices :: proc(
  staging: ^StagingList,
  handle: d.NodeHandle,
  matrices: []matrix[4, 4]f32,
) {
  sync.mutex_lock(&staging.mutex)
  owned_copy := make([dynamic]matrix[4, 4]f32, 0, len(matrices))
  append(&owned_copy, ..matrices[:])
  if old, exists := staging.bone_updates[handle]; exists {
    delete(old.data)
  }
  staging.bone_updates[handle] = {
    data = owned_copy,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_sprite_data :: proc(
  staging: ^StagingList,
  handle: d.SpriteHandle,
  sprite_data: d.SpriteData,
) {
  sync.mutex_lock(&staging.mutex)
  staging.sprite_updates[handle] = {
    data = sprite_data,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_emitter_data :: proc(
  staging: ^StagingList,
  handle: d.EmitterHandle,
  emitter_data: d.EmitterData,
) {
  sync.mutex_lock(&staging.mutex)
  staging.emitter_updates[handle] = {
    data = emitter_data,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_forcefield_data :: proc(
  staging: ^StagingList,
  handle: d.ForceFieldHandle,
  forcefield_data: d.ForceFieldData,
) {
  sync.mutex_lock(&staging.mutex)
  staging.forcefield_updates[handle] = {
    data = forcefield_data,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}

stage_light_data :: proc(
  staging: ^StagingList,
  handle: d.LightHandle,
  light_data: d.LightData,
) {
  sync.mutex_lock(&staging.mutex)
  staging.light_updates[handle] = {
    data = light_data,
    n    = 0,
  }
  sync.mutex_unlock(&staging.mutex)
}
