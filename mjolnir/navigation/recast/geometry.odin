package navigation_recast

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