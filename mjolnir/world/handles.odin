package world

import cont "../containers"
import "../gpu"

Handle :: cont.Handle
Pool :: cont.Pool

NodeHandle :: distinct Handle
MeshHandle :: gpu.MeshHandle
MaterialHandle :: distinct Handle
Image2DHandle :: gpu.Texture2DHandle
ImageCubeHandle :: gpu.TextureCubeHandle
CameraHandle :: distinct Handle
EmitterHandle :: distinct Handle
ForceFieldHandle :: distinct Handle
ClipHandle :: distinct Handle
SpriteHandle :: distinct Handle
LightHandle :: distinct Handle

MAX_CAMERAS :: 64
