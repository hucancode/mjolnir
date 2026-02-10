package shared

import d "../../data"
import "../../gpu"
import vk "vendor:vulkan"

Constants :: struct {
  max_textures:           u32,
  max_cube_textures:      u32,
  max_samplers:           u32,
  sampler_nearest_clamp:  u32,
  sampler_linear_clamp:   u32,
  sampler_nearest_repeat: u32,
  sampler_linear_repeat:  u32,
  light_kind_point:       u32,
  light_kind_directional: u32,
  light_kind_spot:        u32,
}

SHADER_SPEC_DATA := Constants {
  max_textures           = u32(d.MAX_TEXTURES),
  max_cube_textures      = u32(d.MAX_CUBE_TEXTURES),
  max_samplers           = u32(gpu.MAX_SAMPLERS),
  sampler_nearest_clamp  = u32(d.SamplerType.NEAREST_CLAMP),
  sampler_linear_clamp   = u32(d.SamplerType.LINEAR_CLAMP),
  sampler_nearest_repeat = u32(d.SamplerType.NEAREST_REPEAT),
  sampler_linear_repeat  = u32(d.SamplerType.LINEAR_REPEAT),
  light_kind_point       = u32(d.LightType.POINT),
  light_kind_directional = u32(d.LightType.DIRECTIONAL),
  light_kind_spot        = u32(d.LightType.SPOT),
}

SHADER_SPEC_ENTRIES := [?]vk.SpecializationMapEntry {
  {
    constantID = 0,
    offset = u32(offset_of(Constants, max_textures)),
    size = size_of(u32),
  },
  {
    constantID = 1,
    offset = u32(offset_of(Constants, max_cube_textures)),
    size = size_of(u32),
  },
  {
    constantID = 2,
    offset = u32(offset_of(Constants, max_samplers)),
    size = size_of(u32),
  },
  {
    constantID = 3,
    offset = u32(offset_of(Constants, sampler_nearest_clamp)),
    size = size_of(u32),
  },
  {
    constantID = 4,
    offset = u32(offset_of(Constants, sampler_linear_clamp)),
    size = size_of(u32),
  },
  {
    constantID = 5,
    offset = u32(offset_of(Constants, sampler_nearest_repeat)),
    size = size_of(u32),
  },
  {
    constantID = 6,
    offset = u32(offset_of(Constants, sampler_linear_repeat)),
    size = size_of(u32),
  },
  {
    constantID = 7,
    offset = u32(offset_of(Constants, light_kind_point)),
    size = size_of(u32),
  },
  {
    constantID = 8,
    offset = u32(offset_of(Constants, light_kind_directional)),
    size = size_of(u32),
  },
  {
    constantID = 9,
    offset = u32(offset_of(Constants, light_kind_spot)),
    size = size_of(u32),
  },
}

SHADER_SPEC_CONSTANTS := vk.SpecializationInfo {
  mapEntryCount = u32(len(SHADER_SPEC_ENTRIES)),
  pMapEntries   = raw_data(SHADER_SPEC_ENTRIES[:]),
  dataSize      = size_of(Constants),
  pData         = &SHADER_SPEC_DATA,
}
