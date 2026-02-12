package world

import cont "../containers"
import "core:log"

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

Material :: struct {
	features:                 ShaderFeatureSet,
	base_color_factor:        [4]f32,
	metallic_value:           f32,
	roughness_value:          f32,
	emissive_value:           f32,
	type:               MaterialType,
	albedo:             Image2DHandle,
	metallic_roughness: Image2DHandle,
	normal:             Image2DHandle,
	emissive:           Image2DHandle,
	occlusion:          Image2DHandle,
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

material_destroy :: proc(self: ^Material, world: ^World) {
	_ = self
	_ = world
}

create_material :: proc(
	world: ^World,
	features: ShaderFeatureSet = {},
	type: MaterialType = .PBR,
	albedo_handle: Image2DHandle = {},
	metallic_roughness_handle: Image2DHandle = {},
	normal_handle: Image2DHandle = {},
	emissive_handle: Image2DHandle = {},
	occlusion_handle: Image2DHandle = {},
	metallic_value: f32 = 0.0,
	roughness_value: f32 = 1.0,
	emissive_value: f32 = 0.0,
	base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
	handle: MaterialHandle,
	ok: bool,
) #optional_ok {
	mat: ^Material
	handle, mat = cont.alloc(&world.materials, MaterialHandle) or_return
	defer if !ok {
		cont.free(&world.materials, handle)
	}
	material_init(
		mat,
		features,
		type,
		albedo_handle,
		metallic_roughness_handle,
		normal_handle,
		emissive_handle,
		occlusion_handle,
		metallic_value,
		roughness_value,
		emissive_value,
		base_color_factor,
	)
	return handle, true
}
