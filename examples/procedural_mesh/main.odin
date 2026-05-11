package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

wave_node: world.NodeHandle
knot_node: world.NodeHandle
spiral_node: world.NodeHandle

wave_visible: bool = true
knot_visible: bool = true
spiral_visible: bool = true

rotate_speed: mu.Real = 0.4
spin: f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 1000, 700, "Procedural Mesh")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {0, 6, 14}, {0, 1, 0})

  world.spawn(
    &engine.world,
    {6, 12, 6},
    world.create_directional_light_attachment({1, 0.97, 0.93, 5.0}, 20.0, false),
  )

  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground :=
    world.spawn(
      &engine.world,
      {0, -1, 0},
      world.MeshAttachment {
        handle = ground_mesh,
        material = ground_mat,
        cast_shadow = false,
      },
    ) or_else {}
  world.scale(&engine.world, ground, 12.0)

  wave_mat := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {0.3, 0.55, 0.85, 1},
    metallic_value = 0.2,
    roughness_value = 0.5,
  ) or_else {}
  knot_mat := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {0.9, 0.5, 0.2, 1},
    metallic_value = 0.8,
    roughness_value = 0.3,
  ) or_else {}
  spiral_mat := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {0.4, 0.85, 0.4, 1},
    metallic_value = 0.0,
    roughness_value = 0.7,
  ) or_else {}

  wave_geom := build_wave(40, 8.0, 0.6)
  wave_mesh, _, _ := world.create_mesh(&engine.world, wave_geom)
  wave_node =
    world.spawn(
      &engine.world,
      {-6, 0, 0},
      world.MeshAttachment {
        handle = wave_mesh,
        material = wave_mat,
        cast_shadow = true,
      },
    ) or_else {}

  knot_geom := build_torus_knot(2, 3, 200, 12, 1.6, 0.3)
  knot_mesh, _, _ := world.create_mesh(&engine.world, knot_geom)
  knot_node =
    world.spawn(
      &engine.world,
      {0, 1.5, 0},
      world.MeshAttachment {
        handle = knot_mesh,
        material = knot_mat,
        cast_shadow = true,
      },
    ) or_else {}

  spiral_geom := build_helix_tube(120, 8, 2.5, 0.25, 4.0, 3.0)
  spiral_mesh, _, _ := world.create_mesh(&engine.world, spiral_geom)
  spiral_node =
    world.spawn(
      &engine.world,
      {6, 0, 0},
      world.MeshAttachment {
        handle = spiral_mesh,
        material = spiral_mat,
        cast_shadow = true,
      },
    ) or_else {}
}

build_wave :: proc(n: int, size: f32, amp: f32) -> geometry.Geometry {
  vertices := make([]geometry.Vertex, n * n)
  indices := make([]u32, (n - 1) * (n - 1) * 6)
  step := size / f32(n - 1)
  for j in 0 ..< n {
    for i in 0 ..< n {
      x := f32(i) * step - size * 0.5
      z := f32(j) * step - size * 0.5
      y := math.sin(x * 0.9) * math.cos(z * 0.9) * amp
      // partial derivatives for normal
      dy_dx := 0.9 * math.cos(x * 0.9) * math.cos(z * 0.9) * amp
      dy_dz := -0.9 * math.sin(x * 0.9) * math.sin(z * 0.9) * amp
      n_vec := linalg.normalize([3]f32{-dy_dx, 1.0, -dy_dz})
      vertices[j * n + i] = geometry.Vertex {
        position = {x, y, z},
        normal   = n_vec,
        color    = {1, 1, 1, 1},
        uv       = {f32(i) / f32(n - 1), f32(j) / f32(n - 1)},
        tangent  = {1, 0, 0, 1},
      }
    }
  }
  idx := 0
  for j in 0 ..< n - 1 {
    for i in 0 ..< n - 1 {
      a := u32(j * n + i)
      b := u32(j * n + i + 1)
      c := u32((j + 1) * n + i)
      d := u32((j + 1) * n + i + 1)
      indices[idx + 0] = a
      indices[idx + 1] = c
      indices[idx + 2] = b
      indices[idx + 3] = b
      indices[idx + 4] = c
      indices[idx + 5] = d
      idx += 6
    }
  }
  return geometry.Geometry {
    vertices = vertices,
    indices  = indices,
    aabb     = geometry.aabb_from_vertices(vertices),
  }
}

build_torus_knot :: proc(
  p, q: int,
  segments_u: int,
  segments_v: int,
  radius: f32,
  tube: f32,
) -> geometry.Geometry {
  vertices := make([]geometry.Vertex, segments_u * segments_v)
  indices := make([]u32, segments_u * segments_v * 6)
  for i in 0 ..< segments_u {
    u := f32(i) / f32(segments_u) * 2.0 * math.PI
    cu := math.cos(u)
    su := math.sin(u)
    // (p,q) knot curve
    r := math.cos(f32(q) * u) + 2.0
    center := [3]f32 {
      r * math.cos(f32(p) * u),
      math.sin(f32(q) * u),
      r * math.sin(f32(p) * u),
    }
    // forward tangent (finite difference small)
    eps := f32(0.001)
    u2 := u + eps
    r2 := math.cos(f32(q) * u2) + 2.0
    next := [3]f32 {
      r2 * math.cos(f32(p) * u2),
      math.sin(f32(q) * u2),
      r2 * math.sin(f32(p) * u2),
    }
    t := linalg.normalize(next - center)
    up_ref := [3]f32{0, 1, 0}
    bi := linalg.normalize(linalg.cross(t, up_ref))
    nrm := linalg.normalize(linalg.cross(bi, t))
    _ = cu
    _ = su
    for j in 0 ..< segments_v {
      v := f32(j) / f32(segments_v) * 2.0 * math.PI
      offset := nrm * (math.cos(v) * tube) + bi * (math.sin(v) * tube)
      pos := center * radius + offset
      n_vec := linalg.normalize(offset)
      vertices[i * segments_v + j] = geometry.Vertex {
        position = pos,
        normal   = n_vec,
        color    = {1, 1, 1, 1},
        uv       = {f32(i) / f32(segments_u), f32(j) / f32(segments_v)},
        tangent  = {t.x, t.y, t.z, 1},
      }
    }
  }
  idx := 0
  for i in 0 ..< segments_u {
    for j in 0 ..< segments_v {
      i_next := (i + 1) % segments_u
      j_next := (j + 1) % segments_v
      a := u32(i * segments_v + j)
      b := u32(i * segments_v + j_next)
      c := u32(i_next * segments_v + j)
      d := u32(i_next * segments_v + j_next)
      indices[idx + 0] = a
      indices[idx + 1] = b
      indices[idx + 2] = c
      indices[idx + 3] = b
      indices[idx + 4] = d
      indices[idx + 5] = c
      idx += 6
    }
  }
  return geometry.Geometry {
    vertices = vertices,
    indices  = indices,
    aabb     = geometry.aabb_from_vertices(vertices),
  }
}

build_helix_tube :: proc(
  segments_u: int,
  segments_v: int,
  helix_radius: f32,
  tube: f32,
  height: f32,
  turns: f32,
) -> geometry.Geometry {
  vertices := make([]geometry.Vertex, segments_u * segments_v)
  indices := make([]u32, (segments_u - 1) * segments_v * 6)
  for i in 0 ..< segments_u {
    t := f32(i) / f32(segments_u - 1)
    angle := t * turns * 2.0 * math.PI
    center := [3]f32 {
      helix_radius * math.cos(angle),
      t * height,
      helix_radius * math.sin(angle),
    }
    tangent_xy := [3]f32 {
      -helix_radius * math.sin(angle),
      height / (turns * 2.0 * math.PI),
      helix_radius * math.cos(angle),
    }
    tangent := linalg.normalize(tangent_xy)
    up_ref := [3]f32{0, 1, 0}
    side := linalg.normalize(linalg.cross(tangent, up_ref))
    nrm := linalg.normalize(linalg.cross(side, tangent))
    for j in 0 ..< segments_v {
      v := f32(j) / f32(segments_v) * 2.0 * math.PI
      offset := nrm * (math.cos(v) * tube) + side * (math.sin(v) * tube)
      pos := center + offset
      n_vec := linalg.normalize(offset)
      vertices[i * segments_v + j] = geometry.Vertex {
        position = pos,
        normal   = n_vec,
        color    = {1, 1, 1, 1},
        uv       = {t, f32(j) / f32(segments_v)},
        tangent  = {tangent.x, tangent.y, tangent.z, 1},
      }
    }
  }
  idx := 0
  for i in 0 ..< segments_u - 1 {
    for j in 0 ..< segments_v {
      j_next := (j + 1) % segments_v
      a := u32(i * segments_v + j)
      b := u32(i * segments_v + j_next)
      c := u32((i + 1) * segments_v + j)
      d := u32((i + 1) * segments_v + j_next)
      indices[idx + 0] = a
      indices[idx + 1] = b
      indices[idx + 2] = c
      indices[idx + 3] = b
      indices[idx + 4] = d
      indices[idx + 5] = c
      idx += 6
    }
  }
  return geometry.Geometry {
    vertices = vertices,
    indices  = indices,
    aabb     = geometry.aabb_from_vertices(vertices),
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  spin += delta_time * f32(rotate_speed)
  q := quat_y(spin)
  set_spin(&engine.world, wave_node, wave_visible, q, {-6, 0, 0})
  set_spin(&engine.world, knot_node, knot_visible, q, {0, 1.5, 0})
  set_spin(&engine.world, spiral_node, spiral_visible, q, {6, 0, 0})
}

set_spin :: proc(
  w: ^world.World,
  h: world.NodeHandle,
  visible: bool,
  q: quaternion128,
  pos: [3]f32,
) {
  if n, ok := world.node(w, h); ok {
    n.visible = visible
    n.transform.position = pos
    n.transform.rotation = q
    n.transform.is_dirty = true
  }
}

quat_y :: proc(angle: f32) -> quaternion128 {
  half := angle * 0.5
  return quaternion(w = math.cos(half), x = 0, y = math.sin(half), z = 0)
}
