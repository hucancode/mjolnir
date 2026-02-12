package world

import cont "../containers"
import "../gpu"

Handle :: cont.Handle
Pool :: cont.Pool

NodeHandle :: distinct Handle
MeshHandle :: gpu.MeshHandle
MaterialHandle :: distinct Handle
Image2DHandle :: distinct Handle
ImageCubeHandle :: distinct Handle
CameraHandle :: distinct Handle
EmitterHandle :: distinct Handle
ForceFieldHandle :: distinct Handle
ClipHandle :: distinct Handle
SpriteHandle :: distinct Handle
LightHandle :: distinct Handle

MAX_CAMERAS :: 64
