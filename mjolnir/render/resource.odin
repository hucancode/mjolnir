package render

import rd "data"
import "../gpu"

Handle :: rd.Handle
Pool :: rd.Pool
NodeHandle :: rd.NodeHandle
MeshHandle :: rd.MeshHandle
MaterialHandle :: rd.MaterialHandle
Image2DHandle :: gpu.Texture2DHandle
ImageCubeHandle :: gpu.TextureCubeHandle
CameraHandle :: rd.CameraHandle
SphereCameraHandle :: rd.SphereCameraHandle
EmitterHandle :: rd.EmitterHandle
ForceFieldHandle :: rd.ForceFieldHandle
SpriteHandle :: rd.SpriteHandle
LightHandle :: rd.LightHandle

MeshFlag :: rd.MeshFlag
MeshFlagSet :: rd.MeshFlagSet
BufferAllocation :: rd.BufferAllocation
Primitive :: rd.Primitive
MeshData :: rd.MeshData
ShaderFeature :: rd.ShaderFeature
ShaderFeatureSet :: rd.ShaderFeatureSet
MaterialType :: rd.MaterialType
MaterialData :: rd.MaterialData
EmitterData :: rd.EmitterData
ForceFieldData :: rd.ForceFieldData
SpriteData :: rd.SpriteData
NodeFlag :: rd.NodeFlag
NodeFlagSet :: rd.NodeFlagSet
NodeData :: rd.NodeData
Mesh :: rd.Mesh
prepare_mesh_data :: rd.prepare_mesh_data
Material :: rd.Material
prepare_material_data :: rd.prepare_material_data
Emitter :: rd.Emitter
emitter_update_gpu_data :: rd.emitter_update_gpu_data
ForceField :: rd.ForceField
forcefield_update_gpu_data :: rd.forcefield_update_gpu_data
Sprite :: rd.Sprite
