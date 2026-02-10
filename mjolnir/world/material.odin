package world

import cont "../containers"
import d "../data"
import "core:log"

// Re-export types from data module
ShaderFeature :: d.ShaderFeature
ShaderFeatureSet :: d.ShaderFeatureSet
MaterialType :: d.MaterialType
MAX_MATERIALS :: d.MAX_MATERIALS
MaterialData :: d.MaterialData
Material :: d.Material
Color :: d.Color
prepare_material_data :: d.prepare_material_data

material_init :: proc(
	self: ^Material,
	features: ShaderFeatureSet,
	type: MaterialType,
	albedo_handle: d.Image2DHandle,
	metallic_roughness_handle: d.Image2DHandle,
	normal_handle: d.Image2DHandle,
	emissive_handle: d.Image2DHandle,
	occlusion_handle: d.Image2DHandle,
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
	albedo_handle: d.Image2DHandle = {},
	metallic_roughness_handle: d.Image2DHandle = {},
	normal_handle: d.Image2DHandle = {},
	emissive_handle: d.Image2DHandle = {},
	occlusion_handle: d.Image2DHandle = {},
	metallic_value: f32 = 0.0,
	roughness_value: f32 = 1.0,
	emissive_value: f32 = 0.0,
	base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
	auto_purge: bool = false,
) -> (
	handle: d.MaterialHandle,
	ok: bool,
) #optional_ok {
	mat: ^Material
	handle, mat = cont.alloc(&world.materials, d.MaterialHandle) or_return
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
	mat.auto_purge = auto_purge
	return handle, true
}

// Reference counting functions
material_ref :: proc(world: ^World, handle: d.MaterialHandle) -> bool {
	mat := cont.get(world.materials, handle) or_return
	mat.ref_count += 1
	return true
}

material_unref :: proc(
	world: ^World,
	handle: d.MaterialHandle,
) -> (
	ref_count: u32,
	ok: bool,
) #optional_ok {
	mat := cont.get(world.materials, handle) or_return
	if mat.ref_count == 0 {
		return 0, true
	}
	mat.ref_count -= 1
	return mat.ref_count, true
}

purge_unused_materials :: proc(world: ^World) -> (purged_count: int) {
	for &entry, i in world.materials.entries do if entry.active {
		if entry.item.auto_purge && entry.item.ref_count == 0 {
			handle := cont.Handle {
				index      = u32(i),
				generation = entry.generation,
			}
			mat, freed := cont.free(&world.materials, handle)
			if freed {
				material_destroy(mat, world)
				purged_count += 1
			}
		}
	}
	if purged_count > 0 {
		log.infof("Purged %d unused materials", purged_count)
	}
	return
}

purge_unused_resources :: proc(
	world: ^World,
) -> (
	total_purged: int,
) {
	// TODO: purging procedure is now running a full scan O(n) over all resources, which is expensive. we need to optimize this
	total_purged += purge_unused_meshes(world)
	total_purged += purge_unused_materials(world)
	if total_purged > 0 {
		log.infof("Total resources purged: %d", total_purged)
	}
	return
}
