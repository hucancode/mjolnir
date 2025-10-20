package shared

import "../../gpu"
import "../../resources"
import vk "vendor:vulkan"

ShaderSpecConstants :: struct {
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

make_shader_spec_constants :: proc(
) -> (
  ShaderSpecConstants,
  [dynamic]vk.SpecializationMapEntry,
  vk.SpecializationInfo,
) {
  data := ShaderSpecConstants {
    max_textures           = u32(resources.MAX_TEXTURES),
    max_cube_textures      = u32(resources.MAX_CUBE_TEXTURES),
    max_samplers           = u32(gpu.MAX_SAMPLERS),
    sampler_nearest_clamp  = u32(resources.SamplerType.NEAREST_CLAMP),
    sampler_linear_clamp   = u32(resources.SamplerType.LINEAR_CLAMP),
    sampler_nearest_repeat = u32(resources.SamplerType.NEAREST_REPEAT),
    sampler_linear_repeat  = u32(resources.SamplerType.LINEAR_REPEAT),
    light_kind_point       = u32(resources.LightType.POINT),
    light_kind_directional = u32(resources.LightType.DIRECTIONAL),
    light_kind_spot        = u32(resources.LightType.SPOT),
  }
  entries := make([dynamic]vk.SpecializationMapEntry, 0, 10)
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 0,
      offset = u32(offset_of(ShaderSpecConstants, max_textures)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 1,
      offset = u32(offset_of(ShaderSpecConstants, max_cube_textures)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 2,
      offset = u32(offset_of(ShaderSpecConstants, max_samplers)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 3,
      offset = u32(offset_of(ShaderSpecConstants, sampler_nearest_clamp)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 4,
      offset = u32(offset_of(ShaderSpecConstants, sampler_linear_clamp)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 5,
      offset = u32(offset_of(ShaderSpecConstants, sampler_nearest_repeat)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 6,
      offset = u32(offset_of(ShaderSpecConstants, sampler_linear_repeat)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 7,
      offset = u32(offset_of(ShaderSpecConstants, light_kind_point)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 8,
      offset = u32(offset_of(ShaderSpecConstants, light_kind_directional)),
      size = size_of(u32),
    },
  )
  append(
    &entries,
    vk.SpecializationMapEntry {
      constantID = 9,
      offset = u32(offset_of(ShaderSpecConstants, light_kind_spot)),
      size = size_of(u32),
    },
  )
  info := vk.SpecializationInfo {
    mapEntryCount = u32(len(entries)),
    pMapEntries   = raw_data(entries[:]),
    dataSize      = size_of(ShaderSpecConstants),
  }
  return data, entries, info
}
