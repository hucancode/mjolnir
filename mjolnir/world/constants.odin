package world

import cont "../containers"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
// Bone matrix buffer capacity (default: 60MB per frame × 2 frames = 120MB total)
// Override at build time: -define:BONE_BUFFER_CAPACITY_MB=80
BONE_BUFFER_CAPACITY_MB :: #config(BONE_BUFFER_CAPACITY_MB, 60)
MAX_TEXTURES :: 1000
MAX_CUBE_TEXTURES :: 200
MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32
MAX_LIGHTS :: 256
MAX_MESHES :: 65536
MAX_MATERIALS :: 4096
MAX_SPRITES :: 4096
