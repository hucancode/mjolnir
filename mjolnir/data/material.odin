package data

ShaderFeature :: enum {
	ALBEDO_TEXTURE             = 0,
	METALLIC_ROUGHNESS_TEXTURE = 1,
	NORMAL_TEXTURE             = 2,
	EMISSIVE_TEXTURE           = 3,
	OCCLUSION_TEXTURE          = 4,
}

ShaderFeatureSet :: bit_set[ShaderFeature;u32]

MaterialType :: enum {
	PBR,
	UNLIT,
	WIREFRAME,
	TRANSPARENT,
}

MaterialData :: struct {
	albedo_index:             u32,
	metallic_roughness_index: u32,
	normal_index:             u32,
	emissive_index:           u32,
	metallic_value:           f32,
	roughness_value:          f32,
	emissive_value:           f32,
	features:                 ShaderFeatureSet,
	base_color_factor:        [4]f32,
}

Material :: struct {
	using data:         MaterialData,
	type:               MaterialType,
	albedo:             Image2DHandle,
	metallic_roughness: Image2DHandle,
	normal:             Image2DHandle,
	emissive:           Image2DHandle,
	occlusion:          Image2DHandle,
	using meta:         ResourceMetadata,
}

prepare_material_data :: proc(material: ^Material) {
	material.albedo_index = min(MAX_TEXTURES - 1, material.albedo.index)
	material.metallic_roughness_index = min(
		MAX_TEXTURES - 1,
		material.metallic_roughness.index,
	)
	material.normal_index = min(MAX_TEXTURES - 1, material.normal.index)
	material.emissive_index = min(MAX_TEXTURES - 1, material.emissive.index)
}

Color :: enum {
	WHITE,
	BLACK,
	GRAY,
	RED,
	GREEN,
	BLUE,
	YELLOW,
	CYAN,
	MAGENTA,
}

material_init :: proc(
  self: ^Material,
  features: ShaderFeatureSet,
  type: MaterialType,
  albedo_handle: Image2DHandle,
  metallic_roughness_handle: Image2DHandle,
  normal_handle: Image2DHandle,
  emissive_handle: Image2DHandle,
  occlusion_handle: Image2DHandle,
  metallic_value: f32,
  roughness_value: f32,
  emissive_value: f32,
  base_color_factor: [4]f32,
) {
  self.type = type
  self.features = features
  self.albedo = albedo_handle
  self.metallic_roughness = metallic_roughness_handle
  self.normal = normal_handle
  self.emissive = emissive_handle
  self.occlusion = occlusion_handle
  self.metallic_value = metallic_value
  self.roughness_value = roughness_value
  self.emissive_value = emissive_value
  self.base_color_factor = base_color_factor
}