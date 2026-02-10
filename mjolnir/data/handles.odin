package data

import cont "../containers"

Handle :: cont.Handle
Pool :: cont.Pool
NodeHandle :: distinct Handle
MeshHandle :: distinct Handle
MaterialHandle :: distinct Handle
Image2DHandle :: distinct Handle
ImageCubeHandle :: distinct Handle
CameraHandle :: distinct Handle
SphereCameraHandle :: CameraHandle // TODO: for better type-safety, make this distinct
EmitterHandle :: distinct Handle
ForceFieldHandle :: distinct Handle
ClipHandle :: distinct Handle
SpriteHandle :: distinct Handle
LightHandle :: distinct Handle
