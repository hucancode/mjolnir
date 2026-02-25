package camera

import "../../gpu"
import rd "../data"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: rd.FRAMES_IN_FLIGHT
MAX_DEPTH_MIPS_LEVEL :: 16

AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  POSITION           = 1,
  NORMAL             = 2,
  ALBEDO             = 3,
  METALLIC_ROUGHNESS = 4,
  EMISSIVE           = 5,
  DEPTH              = 6,
}

PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  POST_PROCESS = 5,
}

PassTypeSet :: bit_set[PassType;u32]

Camera :: struct {
  // Render pass configuration
  enabled_passes:               PassTypeSet,
  // Visibility culling control flags
  enable_culling:               bool, // If false, skip culling compute pass
  enable_depth_pyramid:         bool, // If false, skip depth pyramid generation
}

// DepthPyramid - Hierarchical depth buffer for occlusion culling (GPU resource)
DepthPyramid :: struct {
  texture:      gpu.Texture2DHandle,
  views:        [MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
  full_view:    vk.ImageView,
  sampler:      vk.Sampler,
  mip_levels:   u32,
  using extent: vk.Extent2D,
}
