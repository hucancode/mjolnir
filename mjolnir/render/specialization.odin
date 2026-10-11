package render

import vk "vendor:vulkan"

SamplerType :: enum u32 {
  NEAREST_CLAMP  = 0,
  LINEAR_CLAMP   = 1,
  NEAREST_REPEAT = 2,
  LINEAR_REPEAT  = 3,
  // bilinear depth comparison (2x2 PCF) for shadow maps
  SHADOW_COMPARE = 4,
}

SpecConstants :: struct {
  max_textures:           u32,
  max_cube_textures:      u32,
  sampler_nearest_clamp:  u32,
  sampler_linear_clamp:   u32,
  sampler_nearest_repeat: u32,
  sampler_linear_repeat:  u32,
  sampler_shadow_compare: u32,
}

SHADER_SPEC_DATA := SpecConstants {
  max_textures           = u32(MAX_TEXTURES),
  max_cube_textures      = u32(MAX_CUBE_TEXTURES),
  sampler_nearest_clamp  = u32(SamplerType.NEAREST_CLAMP),
  sampler_linear_clamp   = u32(SamplerType.LINEAR_CLAMP),
  sampler_nearest_repeat = u32(SamplerType.NEAREST_REPEAT),
  sampler_linear_repeat  = u32(SamplerType.LINEAR_REPEAT),
  sampler_shadow_compare = u32(SamplerType.SHADOW_COMPARE),
}

SHADER_SPEC_ENTRIES := [?]vk.SpecializationMapEntry {
  {
    constantID = 0,
    offset = u32(offset_of(SpecConstants, max_textures)),
    size = size_of(u32),
  },
  {
    constantID = 1,
    offset = u32(offset_of(SpecConstants, max_cube_textures)),
    size = size_of(u32),
  },
  {
    constantID = 2,
    offset = u32(offset_of(SpecConstants, sampler_nearest_clamp)),
    size = size_of(u32),
  },
  {
    constantID = 3,
    offset = u32(offset_of(SpecConstants, sampler_linear_clamp)),
    size = size_of(u32),
  },
  {
    constantID = 4,
    offset = u32(offset_of(SpecConstants, sampler_nearest_repeat)),
    size = size_of(u32),
  },
  {
    constantID = 5,
    offset = u32(offset_of(SpecConstants, sampler_linear_repeat)),
    size = size_of(u32),
  },
  {
    constantID = 6,
    offset = u32(offset_of(SpecConstants, sampler_shadow_compare)),
    size = size_of(u32),
  },
}

SHADER_SPEC_CONSTANTS := vk.SpecializationInfo {
  mapEntryCount = u32(len(SHADER_SPEC_ENTRIES)),
  pMapEntries   = raw_data(SHADER_SPEC_ENTRIES[:]),
  dataSize      = size_of(SpecConstants),
  pData         = &SHADER_SPEC_DATA,
}
