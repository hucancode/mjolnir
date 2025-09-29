package main

import "core:fmt"
import "core:log"
import "core:math/rand"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/navigation/recast"
import "mjolnir/resources"
import "mjolnir/world"
import "vendor:glfw"
import mu "vendor:microui"

// Global engine instance for navmesh demo (avoids stack overflow)
global_navmesh_engine: mjolnir.Engine

Obstacle :: struct {
    handle:       mjolnir.Handle,
    base_position: [3]f32,
    scale:         [3]f32,
    area_type:     u8,
}

navmesh_state: struct {
    floor_handle:   mjolnir.Handle,
    obstacles:      [dynamic]Obstacle,
    nav_mesh_handle: mjolnir.Handle,
    rebuild_needed: bool,
    status:         string,
    config:         recast.Config,
} = {
    status = "Building navigation mesh...",
    config = recast.Config{
        cs = 0.3,
        ch = 0.2,
        walkable_height = 3,
        walkable_radius = 2,
        walkable_climb = 1,
        walkable_slope_angle = 45.0,
    },
}

navmesh_visual_main :: proc() {
    global_navmesh_engine.setup_proc = navmesh_setup
    global_navmesh_engine.update_proc = navmesh_update
    global_navmesh_engine.render2d_proc = navmesh_render2d
    global_navmesh_engine.key_press_proc = navmesh_key_pressed
    global_navmesh_engine.mouse_press_proc = navmesh_mouse_pressed
    global_navmesh_engine.mouse_move_proc = navmesh_mouse_moved

    mjolnir.run(&global_navmesh_engine, 1280, 720, "Navigation Mesh Demo")
}

navmesh_setup :: proc(engine_ptr: ^mjolnir.Engine) {
    log.info("Navigation mesh demo setup")
    navmesh_state.obstacles = make([dynamic]Obstacle, 0)

    // Setup simple lighting
    dir_handle, dir_node := world.spawn(&engine_ptr.world, nil, &engine_ptr.resource_manager)
    dir_attachment := world.create_directional_light_attachment(
        dir_handle,
        &engine_ptr.resource_manager,
        &engine_ptr.gpu_context,
        {0.8, 0.8, 0.8, 1.0},
        true,
    )
    dir_node.attachment = dir_attachment

    point_handle, point_node := world.spawn(&engine_ptr.world, nil, &engine_ptr.resource_manager)
    point_attachment := world.create_point_light_attachment(
        point_handle,
        &engine_ptr.resource_manager,
        &engine_ptr.gpu_context,
        {0.3, 0.3, 0.3, 1.0},
        25,
        false,
    )
    point_node.attachment = point_attachment

    // Configure camera
    camera := mjolnir.get_main_camera(engine_ptr)
    if camera != nil {
        geometry.camera_look_at(
            camera,
            [3]f32{25, 18, 25},
            [3]f32{0, 0, 0},
            [3]f32{0, 1, 0},
        )
    }

    box_geometry := geometry.make_cube()
    defer geometry.delete_geometry(box_geometry)

    box_mesh, mesh_ok := resources.create_mesh_handle(
        &engine_ptr.gpu_context,
        &engine_ptr.resource_manager,
        box_geometry,
    )
    if !mesh_ok {
        log.error("Failed to create box mesh for navmesh demo")
        return
    }

    floor_material, _ := resources.create_material_handle(
        &engine_ptr.resource_manager,
        base_color_factor = {0.4, 0.45, 0.5, 1.0},
    )
    obstacle_material, _ := resources.create_material_handle(
        &engine_ptr.resource_manager,
        base_color_factor = {0.8, 0.35, 0.2, 1.0},
    )

    // Spawn floor
    floor_attachment := world.MeshAttachment{
        handle = box_mesh,
        material = floor_material,
        cast_shadow = true,
    }
    floor_handle, floor_node := world.spawn_node(
        &engine_ptr.world,
        {0, -0.5, 0},
        floor_attachment,
        &engine_ptr.resource_manager,
    )
    geometry.transform_scale_xyz(&floor_node.transform, 20, 0.5, 20)
    world.set_navigation_obstacle(
        &engine_ptr.world,
        &engine_ptr.resource_manager,
        floor_handle,
        true,
        u8(recast.RC_WALKABLE_AREA),
    )
    navmesh_state.floor_handle = floor_handle

    // Spawn static obstacles
    obstacle_specs := [][3]f32{
        {4, 0.5, 4},
        {-5, 0.5, -3},
        {3, 0.5, -6},
        {-2, 0.5, 3},
    }
    obstacle_scales := [][3]f32{
        {1.5, 2.5, 1.5},
        {2.0, 3.0, 1.0},
        {1.2, 2.0, 2.2},
        {1.5, 1.5, 1.5},
    }

    for i in 0 ..< len(obstacle_specs) {
        attachment := world.MeshAttachment{
            handle = box_mesh,
            material = obstacle_material,
            cast_shadow = false,
        }
        handle, node := world.spawn_node(
            &engine_ptr.world,
            obstacle_specs[i],
            attachment,
            &engine_ptr.resource_manager,
        )
        geometry.transform_scale_xyz(
            &node.transform,
            obstacle_scales[i].x,
            obstacle_scales[i].y,
            obstacle_scales[i].z,
        )
        world.set_navigation_obstacle(
            &engine_ptr.world,
            &engine_ptr.resource_manager,
            handle,
            true,
            u8(recast.RC_NULL_AREA),
        )
        append(&navmesh_state.obstacles, Obstacle{
            handle = handle,
            base_position = obstacle_specs[i],
            scale = obstacle_scales[i],
            area_type = u8(recast.RC_NULL_AREA),
        })
    }

    build_navigation_mesh(engine_ptr)
}

navmesh_update :: proc(engine_ptr: ^mjolnir.Engine, delta_time: f32) {
    _ = delta_time
    if navmesh_state.rebuild_needed {
        randomize_obstacles(engine_ptr)
        build_navigation_mesh(engine_ptr)
        navmesh_state.rebuild_needed = false
    }
}

navmesh_render2d :: proc(engine_ptr: ^mjolnir.Engine, ctx: ^mu.Context) {
    _ = engine_ptr
    _ = ctx
}

navmesh_key_pressed :: proc(engine_ptr: ^mjolnir.Engine, key, action, mods: int) {
    _ = mods
    if action != glfw.PRESS {
        return
    }
    switch key {
    case glfw.KEY_R:
        navmesh_state.rebuild_needed = true
        log.info("Queued navmesh rebuild")
    }
}

navmesh_mouse_pressed :: proc(engine_ptr: ^mjolnir.Engine, key, action, mods: int) {
    _ = engine_ptr
    _ = key
    _ = action
    _ = mods
}

navmesh_mouse_moved :: proc(engine_ptr: ^mjolnir.Engine, pos, delta: [2]f64) {
    _ = engine_ptr
    _ = pos
    _ = delta
}

build_navigation_mesh :: proc(engine_ptr: ^mjolnir.Engine) {
    handle, built := world.build_navigation_mesh_from_scene(
        &engine_ptr.world,
        &engine_ptr.resource_manager,
        &engine_ptr.gpu_context,
        navmesh_state.config,
    )
    if !built {
        navmesh_state.status = "Navigation mesh build failed"
        log.error("Failed to build navigation mesh")
        return
    }
    navmesh_state.nav_mesh_handle = handle
    if nav_mesh, ok := resources.get_navmesh(&engine_ptr.resource_manager, handle); ok {
        triangle_count := len(nav_mesh.triangles)
        navmesh_state.status = fmt.tprintf("Triangles: %d", triangle_count)
    } else {
        navmesh_state.status = "Navigation mesh ready"
    }
    log.info("Navigation mesh updated")
}

randomize_obstacles :: proc(engine_ptr: ^mjolnir.Engine) {
    for obstacle in navmesh_state.obstacles[:] {
        node := world.get_node(&engine_ptr.world, obstacle.handle)
        if node == nil {
            continue
        }
        offset_x := (rand.float32() * 2.0 - 1.0) * 2.0
        offset_z := (rand.float32() * 2.0 - 1.0) * 2.0
        geometry.transform_translate(
            &node.transform,
            obstacle.base_position.x + offset_x,
            obstacle.base_position.y,
            obstacle.base_position.z + offset_z,
        )
        geometry.transform_scale_xyz(
            &node.transform,
            obstacle.scale.x,
            obstacle.scale.y,
            obstacle.scale.z,
        )
        world.set_navigation_obstacle(
            &engine_ptr.world,
            &engine_ptr.resource_manager,
            obstacle.handle,
            true,
            obstacle.area_type,
        )
    }
}
