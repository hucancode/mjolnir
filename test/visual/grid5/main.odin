package main

import "core:log"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"

main :: proc() {
	context.logger = log.create_console_logger()
	engine := new(mjolnir.Engine)
	engine.setup_proc = proc(engine: ^mjolnir.Engine) {
		mat, _ := mjolnir.create_material(
			engine,
			type = resources.MaterialType.UNLIT,
			base_color_factor = {0.93, 0.75, 0.2, 1.0},
		)
		cube := geometry.make_cube()
		mesh, _ := mjolnir.create_mesh(engine, cube)
		for z in 0 ..< 5 {
			for x in 0 ..< 5 {
				_, node, _ := mjolnir.spawn(engine, world.MeshAttachment{handle = mesh, material = mat})
				mjolnir.translate(node, f32(x - 2) * 4, 0, f32(z - 2) * 4)
			}
		}
		camera := mjolnir.get_main_camera(engine)
		if camera != nil do resources.camera_look_at(camera, {10, 15, 10}, {0, 0, 0})
	}
	mjolnir.run(engine, 800, 600, "visual-grid-5x5")
}
