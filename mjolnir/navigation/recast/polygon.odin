package recast

import "core:math/linalg"

@(private)
area2 :: proc "contextless" (a, b, c: [2]i32) -> i32 {
  return linalg.cross(b - a, c - a)
}

@(private)
left_on :: proc "contextless" (a, b, c: [2]i32) -> bool {
  return area2(a, b, c) <= 0
}

@(private)
in_cone :: proc "contextless" (a0, a1, a2, p: [2]i32) -> bool {
  if left_on(a0, a1, a2) {
    // p must be left of a1->p->a0 AND left of p->a1->a2
    return left(a1, p, a0) && left(p, a1, a2)
  }
  // p must NOT be (left-or-on a1->p->a2 AND left-or-on p->a1->a0)
  return !(left_on(a1, p, a2) && left_on(p, a1, a0))
}

@(private)
left :: proc "contextless" (a, b, c: [2]i32) -> bool {
  return area2(a, b, c) < 0
}

@(private)
between :: proc "contextless" (a, b, p: [2]i32) -> bool {
  if area2(a, b, p) != 0 {
    return false
  }
  if a.x != b.x {
    return ((a.x <= p.x) && (p.x <= b.x)) || ((a.x >= p.x) && (p.x >= b.x))
  } else {
    return ((a.y <= p.y) && (p.y <= b.y)) || ((a.y >= p.y) && (p.y >= b.y))
  }
}

@(private)
intersect_prop :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
  if area2(a, b, c) == 0 ||
     area2(a, b, d) == 0 ||
     area2(c, d, a) == 0 ||
     area2(c, d, b) == 0 {
    return false
  }
  return (left(a, b, c) != left(a, b, d)) && (left(c, d, a) != left(c, d, b))
}

@(private)
intersect :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
  if intersect_prop(a, b, c, d) {
    return true
  }
  return(
    between(a, b, c) ||
    between(a, b, d) ||
    between(c, d, a) ||
    between(c, d, b) \
  )
}

@(private)
calculate_contour_area :: proc(verts: [][4]i32) -> i32 {
  if len(verts) < 3 do return 0
  nverts := len(verts)
  area: i32 = 0
  j := nverts - 1
  for i in 0 ..< nverts {
    vi := verts[i]
    vj := verts[j]
    area += vi.x * vj.z - vj.x * vi.z
    j = i
  }
  return (area + 1) / 2
}
