package main

import "core:log"
import "core:math"
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
			base_color_factor = {1.0, 0.45, 0.15, 1.0},
		)
		cube := geometry.make_cube()
		for &v in cube.vertices do v.position *= 0.5
		mesh, _ := mjolnir.create_mesh(engine, cube)
		_, node, _ := mjolnir.spawn(engine, world.MeshAttachment{handle = mesh, material = mat})
		mjolnir.translate(node, 0, 0, 0)
		camera := mjolnir.get_main_camera(engine)
		if camera != nil do resources.camera_look_at(camera, {3, 2, 3}, {0, 0, 0})
	}
	mjolnir.run(engine, 800, 600, "visual-single-cube")
}
