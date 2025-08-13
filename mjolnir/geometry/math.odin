package geometry

import "core:math"
import "core:math/linalg"

// 2D Vector operations (working in XZ plane for navigation)

// Calculate perpendicular cross product in 2D (XZ plane)
vec2f_perp :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return linalg.cross(b.xz - a.xz, c.xz - a.xz)
}

// Calculate area of triangle in 2D (XZ plane)
triangle_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return math.abs(linalg.cross(b.xz - a.xz, c.xz - a.xz) * 0.5)
}

// Check if point is inside triangle in 2D (XZ plane)
point_in_triangle_2d :: proc "contextless" (p, a, b, c: [3]f32) -> bool {
    // Use edge testing method - point is inside if it's on the same side of all edges
    cross1 := linalg.cross(b.xz - a.xz, p.xz - a.xz)
    cross2 := linalg.cross(c.xz - b.xz, p.xz - b.xz)
    cross3 := linalg.cross(a.xz - c.xz, p.xz - c.xz)

    // Check if all cross products have the same sign
    return (cross1 >= 0 && cross2 >= 0 && cross3 >= 0) ||
           (cross1 <= 0 && cross2 <= 0 && cross3 <= 0)
}

// Calculate barycentric coordinates for a point in a triangle (2D XZ plane)
barycentric_2d :: proc "contextless" (p: [3]f32, a: [3]f32, b: [3]f32, c: [3]f32) -> [3]f32 {
    // Convert to 2D coordinates (XZ plane)
    px, pz := p.x, p.z
    ax, az := a.x, a.z
    bx, bz := b.x, b.z
    cx, cz := c.x, c.z

    v0x, v0z := bx - ax, bz - az
    v1x, v1z := cx - ax, cz - az
    v2x, v2z := px - ax, pz - az

    d00 := v0x * v0x + v0z * v0z
    d01 := v0x * v1x + v0z * v1z
    d11 := v1x * v1x + v1z * v1z
    d20 := v2x * v0x + v2z * v0z
    d21 := v2x * v1x + v2z * v1z

    denom := d00 * d11 - d01 * d01
    if math.abs(denom) < math.F32_EPSILON {
        return {1.0/3.0, 1.0/3.0, 1.0/3.0}
    }

    v := (d11 * d20 - d01 * d21) / denom
    w := (d00 * d21 - d01 * d20) / denom
    u := 1.0 - v - w

    return {u, v, w}
}

// Find closest point on line segment in 2D (XZ plane)
closest_point_on_segment_2d :: proc "contextless" (p: [3]f32, a: [3]f32, b: [3]f32) -> [3]f32 {
    // Work in XZ plane
    px, pz := p.x, p.z
    ax, az := a.x, a.z
    bx, bz := b.x, b.z

    dx := bx - ax
    dz := bz - az

    if math.abs(dx) < math.F32_EPSILON && math.abs(dz) < math.F32_EPSILON {
        return a
    }

    t := ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)
    t = clamp(t, 0.0, 1.0)

    return {
        ax + t * dx,
        a.y + t * (b.y - a.y), // Interpolate Y
        az + t * dz,
    }
}

// Calculate squared distance from point to line segment in 2D (XZ plane)
dist_point_segment_sq_2d :: proc "contextless" (p, s0, s1: [3]f32) -> f32 {
    closest := closest_point_on_segment_2d(p, s0, s1)
    d := p - closest
    return linalg.dot(d, d)
}

// Point in polygon test (2D XZ plane)
point_in_polygon_2d :: proc "contextless" (pt: [3]f32, verts: [][3]f32) -> bool {
    c := false
    j := len(verts) - 1
    for i := 0; i < len(verts); i += 1 {
        vi := verts[i]
        vj := verts[j]
        // Use >= for one endpoint to handle edge case where ray passes through vertex
        if ((vi.z > pt.z) != (vj.z >= pt.z)) &&
           (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x) {
            c = !c
        }
        j = i
    }
    return c
}

// Calculate polygon area using cross products (2D XZ plane)
poly_area_2d :: proc "contextless" (verts: [][3]f32) -> f32 {
    area: f32 = 0
    for i := 0; i < len(verts); i += 1 {
        a := verts[i].xz
        b := verts[(i + 1) % len(verts)].xz
        area += linalg.cross(a, b)
    }
    return area * 0.5
}

// Check if two line segments intersect in 2D (XZ plane)
intersect_segments_2d :: proc "contextless" (ap, aq, bp, bq: [3]f32) -> (hit: bool, s: f32, t: f32) {
    a_dir := aq.xz - ap.xz
    b_dir := bq.xz - bp.xz
    diff  := bp.xz - ap.xz
    cross := linalg.cross(a_dir, b_dir)
    if math.abs(cross) < math.F32_EPSILON {
        return false, 0, 0
    }
    s = linalg.cross(diff, b_dir) / cross
    t = linalg.cross(diff, a_dir) / cross
    return s >= 0 && s <= 1 && t >= 0 && t <= 1, s, t
}

// 3D Geometry operations

// Intersection test between ray/segment and triangle
intersect_segment_triangle :: proc "contextless" (sp, sq: [3]f32, a, b, c: [3]f32) -> (hit: bool, t: f32) {
    ab := b - a
    ac := c - a
    qp := sp - sq

    // Compute triangle normal
    norm := linalg.cross(ab, ac)

    // Compute denominator
    d := linalg.dot(qp, norm)
    if math.abs(d) < math.F32_EPSILON {
        return false, 0
    }

    // Compute intersection t value
    ap := sp - a
    t = linalg.dot(ap, norm) / d
    if t < 0 || t > 1 {
        return false, 0
    }

    // Compute barycentric coordinates
    e := linalg.cross(qp, ap)
    v := linalg.dot(ac, e) / d
    if v < 0 || v > 1 {
        return false, 0
    }

    w := -linalg.dot(ab, e) / d
    if w < 0 || v + w > 1 {
        return false, 0
    }

    return true, t
}

// Find closest point on triangle in 3D
closest_point_on_triangle :: proc "contextless" (p, a, b, c: [3]f32) -> [3]f32 {
    // Check if P in vertex region outside A
    ab := b - a
    ac := c - a
    ap := p - a
    d1 := linalg.dot(ab, ap)
    d2 := linalg.dot(ac, ap)
    if d1 <= 0 && d2 <= 0 {
        return a
    }

    // Check if P in vertex region outside B
    bp := p - b
    d3 := linalg.dot(ab, bp)
    d4 := linalg.dot(ac, bp)
    if d3 >= 0 && d4 <= d3 {
        return b
    }

    // Check if P in edge region of AB
    vc := d1*d4 - d3*d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        v := d1 / (d1 - d3)
        return a + v * ab
    }

    // Check if P in vertex region outside C
    cp := p - c
    d5 := linalg.dot(ab, cp)
    d6 := linalg.dot(ac, cp)
    if d6 >= 0 && d5 <= d6 {
        return c
    }

    // Check if P in edge region of AC
    vb := d5*d2 - d1*d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        w := d2 / (d2 - d6)
        return a + w * ac
    }

    // Check if P in edge region of BC
    va := d3*d6 - d5*d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
        w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return b + w * (c - b)
    }

    // P inside face region
    denom := 1 / (va + vb + vc)
    v := vb * denom
    w := vc * denom
    return a + ab * v + ac * w
}

// Bounds and overlap tests

// Check if two bounding boxes overlap in 3D
overlap_bounds :: proc "contextless" (amin, amax, bmin, bmax: [3]f32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.y <= bmax.y && amax.y >= bmin.y &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

// Check if two bounding boxes overlap in 2D (XZ plane)
overlap_bounds_2d :: proc "contextless" (amin, amax, bmin, bmax: [3]f32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

// Check if circle overlaps with line segment (2D XZ plane)
overlap_circle_segment :: proc "contextless" (center: [3]f32, radius: f32, p, q: [3]f32) -> bool {
    return dist_point_segment_sq_2d(center, p, q) <= radius*radius
}

// Quantization helpers

// Quantize floating point vector to integer coordinates
quantize_float :: proc "contextless" (v: [3]f32, factor: f32) -> [3]i32 {
    scaled := v * factor + 0.5
    return {i32(math.floor(scaled.x)), i32(math.floor(scaled.y)), i32(math.floor(scaled.z))}
}

// Check if quantized bounds overlap
overlap_quantized_bounds :: proc "contextless" (amin, amax, bmin, bmax: [3]i32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.y <= bmax.y && amax.y >= bmin.y &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

// Direction utilities

// Get next direction in clockwise order (0=+X, 1=+Z, 2=-X, 3=-Z)
next_dir :: proc "contextless" (dir: int) -> int {
    return (dir + 1) & 0x3
}

// Get previous direction in clockwise order
prev_dir :: proc "contextless" (dir: int) -> int {
    return (dir + 3) & 0x3
}

// Integer geometry operations (for exact arithmetic)

// Calculate signed area of triangle formed by three 2D points
// Positive area = counter-clockwise, negative = clockwise
// This is the 2D cross product of vectors (b-a) and (c-a)
area2 :: proc "contextless" (a, b, c: [2]i32) -> i32 {
    return linalg.vector_cross2(b - a, c - a)
}

// Check if point c is to the left of the directed line from a to b
left :: proc "contextless" (a, b, c: [2]i32) -> bool {
    return area2(a, b, c) < 0
}

// Check if point c is to the left or on the directed line from a to b
left_on :: proc "contextless" (a, b, c: [2]i32) -> bool {
    return area2(a, b, c) <= 0
}

// Check if point p is inside the cone formed by three consecutive vertices a0, a1, a2
// a1 is the apex of the cone
in_cone :: proc "contextless" (a0, a1, a2, p: [2]i32) -> bool {
    // If a1 is a convex vertex (a2 is left or on the line from a0 to a1)
    if left_on(a0, a1, a2) {
        // p must be left of a1->p->a0 AND left of p->a1->a2
        return left(a1, p, a0) && left(p, a1, a2)
    }
    // else a1 is reflex
    // p must NOT be (left-or-on a1->p->a2 AND left-or-on p->a1->a0)
    return !(left_on(a1, p, a2) && left_on(p, a1, a0))
}

// Check if point c lies on the line segment from a to b
between :: proc "contextless" (a, b, c: [2]i32) -> bool {
    if area2(a, b, c) != 0 {
        return false // Not collinear
    }
    // If ab not vertical, check betweenness on x; else on y
    if a.x != b.x {
        return ((a.x <= c.x) && (c.x <= b.x)) || ((a.x >= c.x) && (c.x >= b.x))
    } else {
        return ((a.y <= c.y) && (c.y <= b.y)) || ((a.y >= c.y) && (c.y >= b.y))
    }
}

// Check if line segments ab and cd intersect properly (at a point interior to both segments)
intersect_prop :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
    // Eliminate improper cases (endpoints touching)
    if area2(a, b, c) == 0 ||
       area2(a, b, d) == 0 ||
       area2(c, d, a) == 0 ||
       area2(c, d, b) == 0 {
        return false
    }

    // Check if c and d are on opposite sides of ab, and a and b are on opposite sides of cd
    return (left(a, b, c) != left(a, b, d)) &&
           (left(c, d, a) != left(c, d, b))
}

// Check if line segments ab and cd intersect (properly or improperly)
intersect :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
    if intersect_prop(a, b, c, d) {
        return true
    }
    // Check if any endpoint lies on the other segment
    return between(a, b, c) ||
           between(a, b, d) ||
           between(c, d, a) ||
           between(c, d, b)
}


// Calculate triangle normal
calc_tri_normal :: proc(v0, v1, v2: [3]f32) -> (norm: [3]f32) {
    e0 := v1 - v0
    e1 := v2 - v0
    norm = linalg.cross(e0, e1)
    norm = linalg.normalize(norm)
    return
}

// Calculate polygon normal using Newell's method
calc_poly_normal :: proc "contextless" (verts: [][3]f32) -> [3]f32 {
    normal := [3]f32{0, 0, 0}

    for i := 0; i < len(verts); i += 1 {
        v0 := verts[i]
        v1 := verts[(i + 1) % len(verts)]

        normal.x += (v0.y - v1.y) * (v0.z + v1.z)
        normal.y += (v0.z - v1.z) * (v0.x + v1.x)
        normal.z += (v0.x - v1.x) * (v0.y + v1.y)
    }

    // Normalize the result
    length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
    if length > math.F32_EPSILON {
        normal /= length
    }

    return normal
}

// Utility functions

// Next power of two
next_pow2 :: proc "contextless" (v: u32) -> u32 {
    val := v
    val -= 1
    val |= val >> 1
    val |= val >> 2
    val |= val >> 4
    val |= val >> 8
    val |= val >> 16
    val += 1
    return val
}

// Integer log base 2
ilog2 :: proc "contextless" (v: u32) -> u32 {
    val := v
    r: u32 = 0
    shift: u32

    shift = u32(val > 0xffff) << 4
    val >>= shift
    r |= shift

    shift = u32(val > 0xff) << 3
    val >>= shift
    r |= shift

    shift = u32(val > 0xf) << 2
    val >>= shift
    r |= shift

    shift = u32(val > 0x3) << 1
    val >>= shift
    r |= shift

    r |= val >> 1
    return r
}

// Align value to given alignment
align :: proc "contextless" (value, alignment: int) -> int {
    return (value + alignment - 1) & ~(alignment - 1)
}
