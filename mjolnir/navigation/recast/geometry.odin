package navigation_recast
import "core:math"
import "core:math/linalg"

// Math constants
EPSILON :: 1e-6

@(optimization_mode="none")
vec2f_perp :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return linalg.cross(b.xz - a.xz, c.xz - a.xz)
}

// Direction utilities
next_dir :: proc "contextless" (dir: int) -> int {
    return (dir + 1) & 0x3
}

prev_dir :: proc "contextless" (dir: int) -> int {
    return (dir + 3) & 0x3
}

// Quantization helpers
quantize_float :: proc "contextless" (v: [3]f32, factor: f32) -> [3]i32 {
    scaled := v * factor + 0.5
    return {i32(math.floor(scaled.x)), i32(math.floor(scaled.y)), i32(math.floor(scaled.z))}
}


@(optimization_mode="none")
overlap_quantized_bounds :: proc "contextless" (amin, amax, bmin, bmax: [3]i32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.y <= bmax.y && amax.y >= bmin.y &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

@(optimization_mode="none")
triangle_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return math.abs(linalg.cross(b.xz - a.xz, c.xz - a.xz) * 0.5)
}

// Point in polygon test
@(optimization_mode="none")
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
// Intersection and geometry utilities
@(optimization_mode="none")
intersect_segment_triangle :: proc "contextless" (sp, sq: [3]f32, a, b, c: [3]f32) -> (hit: bool, t: f32) {
    ab := b - a
    ac := c - a
    qp := sp - sq

    // Compute triangle normal
    norm := linalg.cross(ab, ac)

    // Compute denominator
    d := linalg.dot(qp, norm)
    if math.abs(d) < EPSILON {
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

@(optimization_mode="none")
closest_point_on_triangle :: proc "contextless" (p, a, b, c: [3]f32) -> [3]f32 {
    // Check if P in vertex region outside A
    ab := b - a
    ac := c - a
    ap := p - a
    d1 := linalg.dot(ab, ap)
    d2 := linalg.dot(ac, ap)
    if d1 <= 0 && d2 <= 0 {
        return a // barycentric coordinates (1,0,0)
    }

    // Check if P in vertex region outside B
    bp := p - b
    d3 := linalg.dot(ab, bp)
    d4 := linalg.dot(ac, bp)
    if d3 >= 0 && d4 <= d3 {
        return b // barycentric coordinates (0,1,0)
    }

    // Check if P in edge region of AB
    vc := d1*d4 - d3*d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        v := d1 / (d1 - d3)
        return a + ab * v // barycentric coordinates (1-v,v,0)
    }

    // Check if P in vertex region outside C
    cp := p - c
    d5 := linalg.dot(ab, cp)
    d6 := linalg.dot(ac, cp)
    if d6 >= 0 && d5 <= d6 {
        return c // barycentric coordinates (0,0,1)
    }

    // Check if P in edge region of AC
    vb := d5*d2 - d1*d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        w := d2 / (d2 - d6)
        return a + ac * w // barycentric coordinates (1-w,0,w)
    }

    // Check if P in edge region of BC
    va := d3*d6 - d5*d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
        w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return b + (c - b) * w // barycentric coordinates (0,1-w,w)
    }

    // P inside face region. Compute Q through barycentric coordinates (u,v,w)
    denom := 1 / (va + vb + vc)
    v := vb * denom
    w := vc * denom
    return a + ab * v + ac * w
}

@(optimization_mode="none")
dist_point_segment_sq_2d :: proc "contextless" (pt, p, q: [3]f32) -> f32 {
    pq := q - p
    ppt := pt - p
    ds := linalg.length2(pq.xz)
    if ds > 0 {
        t := math.clamp(linalg.dot(ppt.xz, pq.xz) / ds, 0.0, 1.0)
        closest := p.xz + pq.xz * t
        return linalg.length2(pt.xz - closest)
    }
    return linalg.length2(ppt.xz)
}

@(optimization_mode="none")
dist_point_segment_sq :: proc "contextless" (pt, p, q: [3]f32) -> f32 {
    pq := q - p
    dx := linalg.dot(pt - p, pq)
    if dx <= 0 {
        return linalg.length2(pt - p)
    }
    sq := linalg.length2(pq)
    if dx >= sq {
        return linalg.length2(pt - q)
    }
    return linalg.length2(pt - (p + pq * (dx/sq)))
}

// Calculate squared distance from point to triangle
@(optimization_mode="none")
dist_point_triangle_sq :: proc "contextless" (p, a, b, c: [3]f32) -> f32 {
    closest := closest_point_on_triangle(p, a, b, c)
    return linalg.length2(p - closest)
}

// Compute normal of a polygon
@(optimization_mode="none")
calc_poly_normal :: proc "contextless" (verts: [][3]f32) -> [3]f32 {
    // Use Newell's method to compute robust polygon normal
    n : [3]f32
    for i := 0; i < len(verts); i += 1 {
        v1 := verts[i]
        v2 := verts[(i + 1) % len(verts)]
        // Cross product of edge with origin
        n.x += (v1.y - v2.y) * (v1.z + v2.z)
        n.y += (v1.z - v2.z) * (v1.x + v2.x)
        n.z += (v1.x - v2.x) * (v1.y + v2.y)
    }
    return linalg.normalize(n)
}

// Calculate polygon area using linalg cross products
@(optimization_mode="none")
poly_area_2d :: proc "contextless" (verts: [][3]f32) -> f32 {
    area: f32 = 0
    for i := 0; i < len(verts); i += 1 {
        a := verts[i].xz
        b := verts[(i + 1) % len(verts)].xz
        area += linalg.cross(a, b)
    }
    return area * 0.5
}

// Check if two line segments intersect
@(optimization_mode="none")
intersect_segments_2d :: proc "contextless" (ap, aq, bp, bq: [3]f32) -> (hit: bool, s: f32, t: f32) {
    a_dir := aq.xz - ap.xz;
    b_dir := bq.xz - bp.xz;
    diff  := bp.xz - ap.xz;
    cross := linalg.cross(a_dir, b_dir);
    if math.abs(cross) < EPSILON {
        return false, 0, 0;
    }
    s = linalg.cross(diff, b_dir) / cross;
    t = linalg.cross(diff, a_dir) / cross;
    return s >= 0 && s <= 1 && t >= 0 && t <= 1, s, t;
}

// Overlap tests for circles and boxes
@(optimization_mode="none")
overlap_circle_segment :: proc "contextless" (center: [3]f32, radius: f32, p, q: [3]f32) -> bool {
    return dist_point_segment_sq_2d(center, p, q) <= radius*radius
}

@(optimization_mode="none")
overlap_bounds :: proc "contextless" (amin, amax, bmin, bmax: [3]f32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

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
// Core geometry functions that work with raw vectors
// These are designed to be testable and reusable without indirection

// We use [2]i32 for 2D integer coordinates (x,z) in navigation mesh space

// Calculate signed area of triangle formed by three 2D points
// Positive area = counter-clockwise, negative = clockwise
area2 :: proc "contextless" (a, b, c: [2]i32) -> i32 {
    return (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
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
        // p must be left of a1->a0 AND left of p->a1->a2
        return left(a1, p, a0) && left(p, a1, a2)
    }
    // else a1 is reflex
    // p must NOT be (left of a1->p->a2 AND left of p->a1->a0)
    return !(left_on(a1, p, a2) && left_on(p, a1, a0))
}

// vequal removed - use direct comparison (a == b) in Odin

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
