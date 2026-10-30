// Geometry on its own: build meshes, ray-trace them through a BVH, and frustum-cull a field of boxes. The command line writes artifacts/modules/geometry_only/{shapes.obj,render.png,cull.svg}; the web page shows them.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import stbi "vendor:stb/image"
import "mjolnir/geometry"

WIDTH :: 640
HEIGHT :: 400

build_scene :: proc() -> geometry.Mesh {
  parts := []geometry.Mesh {
    geometry.make_quad(),
    geometry.make_sphere(32, 24, 0.8),
    geometry.make_torus(48, 24, 0.8, 0.25),
    geometry.make_cube(),
    geometry.make_cylinder(),
    geometry.make_capsule(),
  }
  defer for p in parts do geometry.destroy(p)
  place :: proc(position: [3]f32, scale: f32 = 1, angle: f32 = 0) -> geometry.Transform {
    return {position = position, rotation = linalg.quaternion_angle_axis(angle, [3]f32{1, 0, 0}), scale = scale}
  }
  transforms := []geometry.Transform {
    place({0, 0, 0}, 6),
    place({-2.2, 0.8, 0}),
    place({0, 0.8, 0}, 1, math.PI / 3),
    place({2.2, 0.5, 0}, 0.5),
    place({-1.1, 0.5, -2.2}, 0.5),
    place({1.1, 0.8, -2.2}, 0.5),
  }
  return geometry.mesh_merge(parts, transforms)
}

obj :: proc(mesh: geometry.Mesh) -> string {
  b := strings.builder_make(context.temp_allocator)
  for v in mesh.vertices do fmt.sbprintfln(&b, "v %f %f %f", v.position.x, v.position.y, v.position.z)
  for i := 0; i + 2 < len(mesh.indices); i += 3 {
    fmt.sbprintfln(&b, "f %d %d %d", mesh.indices[i] + 1, mesh.indices[i + 1] + 1, mesh.indices[i + 2] + 1)
  }
  return strings.to_string(b)
}

trace :: proc(mesh: geometry.Mesh) -> (image: []u8, hits: int) {
  triangle_count := len(mesh.indices) / 3
  triangles := make([]u32, triangle_count, context.temp_allocator)
  bounds := make([]geometry.Aabb, triangle_count, context.temp_allocator)
  for &t, i in triangles {
    t = u32(i)
    a, b, c := corners(mesh, t)
    bounds[i] = {linalg.min(a, linalg.min(b, c)), linalg.max(a, linalg.max(b, c))}
  }
  bvh: geometry.BVH(u32)
  geometry.bvh_build(&bvh, triangles, bounds)
  defer geometry.destroy(&bvh)

  eye := [3]f32{0, 4, 7}
  forward := linalg.normalize([3]f32{0, 0.4, 0} - eye)
  right := linalg.normalize(linalg.cross(forward, [3]f32{0, 1, 0}))
  up := linalg.cross(right, forward)
  half_height := math.tan(f32(math.PI) / 8)
  half_width := half_height * WIDTH / HEIGHT
  sun := linalg.normalize([3]f32{0.4, 1, 0.6})
  pixels := make([]u8, WIDTH * HEIGHT * 3, context.temp_allocator)
  candidates := make([dynamic]u32, context.temp_allocator)
  for y in 0 ..< HEIGHT {
    for x in 0 ..< WIDTH {
      u := (2 * (f32(x) + 0.5) / WIDTH - 1) * half_width
      v := (1 - 2 * (f32(y) + 0.5) / HEIGHT) * half_height
      ray := geometry.Ray{eye, linalg.normalize(forward + right * u + up * v)}
      geometry.bvh_query_ray(&bvh, ray, 100, &candidates)
      nearest, normal, hit := f32(math.F32_MAX), [3]f32{}, false
      for t in candidates {
        a, b, c := corners(mesh, t)
        if d, ok := geometry.ray_triangle_intersection(ray, a, b, c); ok && d < nearest {
          nearest, normal, hit = d, linalg.normalize(linalg.cross(b - a, c - a)), true
        }
      }
      color := [3]f32{0.15, 0.17, 0.22}
      if hit {
        hits += 1
        if linalg.dot(normal, ray.direction) > 0 do normal = -normal
        light := 0.2 + 0.8 * max(linalg.dot(normal, sun), 0)
        color = (normal * 0.5 + 0.5) * light
      }
      p := pixels[(y * WIDTH + x) * 3:]
      for k in 0 ..< 3 do p[k] = u8(clamp(color[k], 0, 1) * 255)
    }
  }
  return png(WIDTH, HEIGHT, 3, pixels), hits
}

png :: proc(w, h, channels: int, pixels: []u8) -> []u8 {
  out := make([dynamic]u8, context.temp_allocator)
  write :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
    context = runtime.default_context()
    append(cast(^[dynamic]u8)ctx, ..([^]u8)(data)[:size])
  }
  stbi.write_png_to_func(write, &out, i32(w), i32(h), i32(channels), raw_data(pixels), i32(w * channels))
  return out[:]
}

corners :: proc(mesh: geometry.Mesh, triangle: u32) -> (a, b, c: [3]f32) {
  i := mesh.indices[triangle * 3:]
  return mesh.vertices[i[0]].position, mesh.vertices[i[1]].position, mesh.vertices[i[2]].position
}

cull :: proc() -> (svg: string, kept, total: int) {
  eye := [3]f32{0, 2, 0}
  view := linalg.matrix4_look_at(eye, [3]f32{6, 2, 8}, [3]f32{0, 1, 0})
  projection := geometry.make_perspective_matrix(math.PI / 3, 16.0 / 9.0, 0.5, 18)
  frustum := geometry.make_frustum(projection * view)
  SCALE :: 20
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-400 -400 800 800" style="background:#20232b">`)
  for gx in -9 ..= 9 {
    for gz in -9 ..= 9 {
      center := [3]f32{f32(gx) * 2, 0, f32(gz) * 2}
      spin := linalg.matrix4_translate(center) * linalg.matrix4_rotate(f32(gx * 7 + gz * 3) * 0.1, [3]f32{0, 1, 0})
      box := geometry.aabb_transform({{-0.6, 0, -0.3}, {0.6, 4, 0.3}}, spin)
      inside := geometry.frustum_test_aabb(frustum, box)
      total += 1
      if inside do kept += 1
      fmt.sbprintfln(&b, `<rect x="%f" y="%f" width="%f" height="%f" fill="%s"/>`, box.min.x * SCALE, box.min.z * SCALE, (box.max.x - box.min.x) * SCALE, (box.max.z - box.min.z) * SCALE, "#7fd17f" if inside else "#555a66")
    }
  }
  inv := linalg.inverse(projection * view)
  fan: [4][3]f32
  for corner, i in ([4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) {
    far := inv * [4]f32{corner.x, corner.y, 1, 1}
    fan[i] = far.xyz / far.w
  }
  fmt.sbprintfln(&b, `<polygon points="%f,%f %f,%f %f,%f" fill="none" stroke="#ffd166" stroke-width="2"/>`, eye.x * SCALE, eye.z * SCALE, fan[0].x * SCALE, fan[0].z * SCALE, fan[1].x * SCALE, fan[1].z * SCALE)
  fmt.sbprintln(&b, "</svg>")
  return strings.to_string(b), kept, total
}
