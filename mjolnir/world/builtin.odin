package world

import cont "../containers"
import "../geometry"
import "core:log"

get_builtin_material :: proc(
	world: ^World,
	color: Color,
) -> MaterialHandle {
	return world.builtin_materials[color]
}

get_builtin_mesh :: proc(
	world: ^World,
	primitive: Primitive,
) -> MeshHandle {
	return world.builtin_meshes[primitive]
}

init_builtin_materials :: proc(world: ^World) {
	log.info("Creating builtin materials...")
	colors := [len(Color)][4]f32 {
		{1.0, 1.0, 1.0, 1.0}, // WHITE
		{0.0, 0.0, 0.0, 1.0}, // BLACK
		{0.3, 0.3, 0.3, 1.0}, // GRAY
		{1.0, 0.0, 0.0, 1.0}, // RED
		{0.0, 1.0, 0.0, 1.0}, // GREEN
		{0.0, 0.0, 1.0, 1.0}, // BLUE
		{1.0, 1.0, 0.0, 1.0}, // YELLOW
		{0.0, 1.0, 1.0, 1.0}, // CYAN
		{1.0, 0.0, 1.0, 1.0}, // MAGENTA
	}
	for color, i in colors {
		world.builtin_materials[i] =
		create_material(world, type = .PBR, base_color_factor = color) or_continue
		stage_material_data(&world.staging, world.builtin_materials[i])
	}
	log.info("Builtin materials created successfully")
}

init_builtin_meshes :: proc(world: ^World) {
	log.info("Creating builtin meshes...")
	world.builtin_meshes[Primitive.CUBE], _, _ = create_mesh(
		world,
		geometry.make_cube(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.CUBE])
	world.builtin_meshes[Primitive.SPHERE], _, _ = create_mesh(
		world,
		geometry.make_sphere(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.SPHERE])
	world.builtin_meshes[Primitive.QUAD_XZ], _, _ = create_mesh(
		world,
		geometry.make_quad(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.QUAD_XZ])
	world.builtin_meshes[Primitive.QUAD_XY], _, _ = create_mesh(
		world,
		geometry.make_billboard_quad(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.QUAD_XY])
	world.builtin_meshes[Primitive.CONE], _, _ = create_mesh(
		world,
		geometry.make_cone(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.CONE])
	world.builtin_meshes[Primitive.CAPSULE], _, _ = create_mesh(
		world,
		geometry.make_capsule(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.CAPSULE])
	world.builtin_meshes[Primitive.CYLINDER], _, _ = create_mesh(
		world,
		geometry.make_cylinder(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.CYLINDER])
	world.builtin_meshes[Primitive.TORUS], _, _ = create_mesh(
		world,
		geometry.make_torus(),
	)
	stage_mesh_data(&world.staging, world.builtin_meshes[Primitive.TORUS])
	log.info("Builtin meshes created successfully")
}
