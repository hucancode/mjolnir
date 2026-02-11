package world

import "core:sync"

StagingList :: struct {
  transforms: map[NodeHandle]u32,
  node_data:  map[NodeHandle]u32,
  mesh_updates: map[MeshHandle]u32,
  material_updates: map[MaterialHandle]u32,
  bone_updates: map[NodeHandle]u32,
  sprite_updates: map[SpriteHandle]u32,
  emitter_updates: map[EmitterHandle]u32,
  forcefield_updates: map[ForceFieldHandle]u32,
  light_updates: map[LightHandle]u32,
  camera_updates: map[CameraHandle]u32,
  spherical_camera_updates: map[SphereCameraHandle]u32,
  mutex: sync.Mutex,
}

staging_init :: proc(staging: ^StagingList) {
  staging.transforms = make(map[NodeHandle]u32)
  staging.node_data = make(map[NodeHandle]u32)
  staging.mesh_updates = make(map[MeshHandle]u32)
  staging.material_updates = make(map[MaterialHandle]u32)
  staging.bone_updates = make(map[NodeHandle]u32)
  staging.sprite_updates = make(map[SpriteHandle]u32)
  staging.emitter_updates = make(map[EmitterHandle]u32)
  staging.forcefield_updates = make(map[ForceFieldHandle]u32)
  staging.light_updates = make(map[LightHandle]u32)
  staging.camera_updates = make(map[CameraHandle]u32)
  staging.spherical_camera_updates = make(map[SphereCameraHandle]u32)
}

staging_destroy :: proc(staging: ^StagingList) {
  delete(staging.transforms)
  delete(staging.node_data)
  delete(staging.mesh_updates)
  delete(staging.material_updates)
  delete(staging.bone_updates)
  delete(staging.sprite_updates)
  delete(staging.emitter_updates)
  delete(staging.forcefield_updates)
  delete(staging.light_updates)
  delete(staging.camera_updates)
  delete(staging.spherical_camera_updates)
}

stage_node_transform :: proc(
  staging: ^StagingList,
  handle: NodeHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.transforms[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_node_data :: proc(
  staging: ^StagingList,
  handle: NodeHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.node_data[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_mesh_data :: proc(
  staging: ^StagingList,
  handle: MeshHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.mesh_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_material_data :: proc(
  staging: ^StagingList,
  handle: MaterialHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.material_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_bone_matrices :: proc(
  staging: ^StagingList,
  handle: NodeHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.bone_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_sprite_data :: proc(
  staging: ^StagingList,
  handle: SpriteHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.sprite_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_emitter_data :: proc(
  staging: ^StagingList,
  handle: EmitterHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.emitter_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_forcefield_data :: proc(
  staging: ^StagingList,
  handle: ForceFieldHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.forcefield_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_light_data :: proc(
  staging: ^StagingList,
  handle: LightHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.light_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_camera_data :: proc(
  staging: ^StagingList,
  handle: CameraHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.camera_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}

stage_spherical_camera_data :: proc(
  staging: ^StagingList,
  handle: SphereCameraHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.spherical_camera_updates[handle] = 0
  sync.mutex_unlock(&staging.mutex)
}
