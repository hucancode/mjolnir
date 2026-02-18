package world

import "core:sync"

StagingOp :: enum u16 {
  Update,
  Remove,
}

StagingEntry :: struct {
  age: u16,
  op:  StagingOp,
}

StagingList :: struct {
  transforms:         map[NodeHandle]StagingEntry,
  node_data:          map[NodeHandle]StagingEntry,
  mesh_updates:       map[MeshHandle]StagingEntry,
  material_updates:   map[MaterialHandle]StagingEntry,
  bone_updates:       map[NodeHandle]StagingEntry,
  sprite_updates:     map[SpriteHandle]StagingEntry,
  emitter_updates:    map[EmitterHandle]StagingEntry,
  forcefield_updates: map[ForceFieldHandle]StagingEntry,
  light_updates:      map[NodeHandle]StagingEntry,
  camera_updates:     map[CameraHandle]StagingEntry,
  mutex:              sync.Mutex,
}

staging_init :: proc(staging: ^StagingList) {
  staging.transforms = make(map[NodeHandle]StagingEntry)
  staging.node_data = make(map[NodeHandle]StagingEntry)
  staging.mesh_updates = make(map[MeshHandle]StagingEntry)
  staging.material_updates = make(map[MaterialHandle]StagingEntry)
  staging.bone_updates = make(map[NodeHandle]StagingEntry)
  staging.sprite_updates = make(map[SpriteHandle]StagingEntry)
  staging.emitter_updates = make(map[EmitterHandle]StagingEntry)
  staging.forcefield_updates = make(map[ForceFieldHandle]StagingEntry)
  staging.light_updates = make(map[NodeHandle]StagingEntry)
  staging.camera_updates = make(map[CameraHandle]StagingEntry)
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
}

stage_node_transform :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.transforms[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_node_transform_removal :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.transforms[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_node_data :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.node_data[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_node_data_removal :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.node_data[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_mesh_data :: proc(staging: ^StagingList, handle: MeshHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.mesh_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_mesh_removal :: proc(staging: ^StagingList, handle: MeshHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.mesh_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_material_data :: proc(staging: ^StagingList, handle: MaterialHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.material_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_material_removal :: proc(staging: ^StagingList, handle: MaterialHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.material_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_bone_matrices :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.bone_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_bone_matrices_removal :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.bone_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_sprite_data :: proc(staging: ^StagingList, handle: SpriteHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.sprite_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_sprite_removal :: proc(staging: ^StagingList, handle: SpriteHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.sprite_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_emitter_data :: proc(staging: ^StagingList, handle: EmitterHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.emitter_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_emitter_removal :: proc(staging: ^StagingList, handle: EmitterHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.emitter_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_forcefield_data :: proc(
  staging: ^StagingList,
  handle: ForceFieldHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.forcefield_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_forcefield_removal :: proc(
  staging: ^StagingList,
  handle: ForceFieldHandle,
) {
  sync.mutex_lock(&staging.mutex)
  staging.forcefield_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_light_data :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.light_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_light_removal :: proc(staging: ^StagingList, handle: NodeHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.light_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}

stage_camera_data :: proc(staging: ^StagingList, handle: CameraHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.camera_updates[handle] = {op = .Update}
  sync.mutex_unlock(&staging.mutex)
}

stage_camera_removal :: proc(staging: ^StagingList, handle: CameraHandle) {
  sync.mutex_lock(&staging.mutex)
  staging.camera_updates[handle] = {op = .Remove}
  sync.mutex_unlock(&staging.mutex)
}
