package world

import cont "../containers"
import d "../data"
import "core:log"

init_builtin_materials :: proc(world: ^World) {
	log.info("Creating builtin materials...")
	colors := [len(d.Color)][4]f32 {
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
		if mat, ok := cont.get(world.materials, world.builtin_materials[i]); ok {
			d.prepare_material_data(mat)
		}
	}
	log.info("Builtin materials created successfully")
}
