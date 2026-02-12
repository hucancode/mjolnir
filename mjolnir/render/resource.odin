package render

import "../gpu"
import rd "data"

Handle :: rd.Handle
NodeHandle :: rd.NodeHandle
MeshHandle :: rd.MeshHandle
MaterialHandle :: rd.MaterialHandle
Image2DHandle :: gpu.Texture2DHandle
ImageCubeHandle :: gpu.TextureCubeHandle
CameraHandle :: rd.CameraHandle
EmitterHandle :: rd.EmitterHandle
ForceFieldHandle :: rd.ForceFieldHandle
SpriteHandle :: rd.SpriteHandle
LightHandle :: rd.LightHandle

MeshFlag :: rd.MeshFlag
MeshFlagSet :: rd.MeshFlagSet
BufferAllocation :: rd.BufferAllocation
Primitive :: rd.Primitive
ShaderFeature :: rd.ShaderFeature
ShaderFeatureSet :: rd.ShaderFeatureSet
NodeFlag :: rd.NodeFlag
NodeFlagSet :: rd.NodeFlagSet
Node :: rd.Node
Mesh :: rd.Mesh
Material :: rd.Material
Emitter :: rd.Emitter
ForceField :: rd.ForceField
Sprite :: rd.Sprite
Light :: rd.Light
LightType :: rd.LightType
