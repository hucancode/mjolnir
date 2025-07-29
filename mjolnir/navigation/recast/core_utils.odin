package navigation_recast

import "core:slice"
import "core:math"

// Get offset of a tile in the tile grid
calc_tile_loc :: proc "contextless" (x, y: i32) -> u32 {
    return u32(x) & 0x0000ffff | (u32(y) & 0x0000ffff) << 16
}

// Calculate grid location from position
calc_grid_location :: proc "contextless" (pos: [3]f32, cell_size: f32) -> (x, y: i32) {
    x = i32(math.floor(pos.x / cell_size))
    y = i32(math.floor(pos.z / cell_size))
    return
}

// Encode a polygon reference
encode_poly_id :: proc "contextless" (salt, it, ip: u32) -> Poly_Ref {
    when RC_LARGE_WORLDS {
        return Poly_Ref((u64(salt) << 32) | (u64(it) << 20) | u64(ip))
    } else {
        return Poly_Ref((salt << 16) | (it << 12) | ip)
    }
}

// Decode a polygon reference
decode_poly_id :: proc "contextless" (ref: Poly_Ref) -> (salt, it, ip: u32) {
    when RC_LARGE_WORLDS {
        id := u64(ref)
        salt = u32((id >> 32) & 0xffffffff)
        it = u32((id >> 20) & 0x0fff)
        ip = u32(id & 0xfffff)
    } else {
        id := u32(ref)
        salt = (id >> 16) & 0xffff
        it = (id >> 12) & 0x0f
        ip = id & 0xfff
    }
    return
}

// Get salt from poly ref
poly_id_salt :: proc "contextless" (ref: Poly_Ref) -> u32 {
    salt, _, _ := decode_poly_id(ref)
    return salt
}

// Get tile index from poly ref
poly_id_tile :: proc "contextless" (ref: Poly_Ref) -> u32 {
    _, it, _ := decode_poly_id(ref)
    return it
}

// Get poly index from poly ref
poly_id_poly :: proc "contextless" (ref: Poly_Ref) -> u32 {
    _, _, ip := decode_poly_id(ref)
    return ip
}

// Calculate distance field value
calc_dist_field_value :: proc "contextless" (distance: f32, max_dist: f32) -> u16 {
    if distance < 0 do return 0
    if distance >= max_dist do return 0xffff
    return u16(distance / max_dist * 0xffff)
}

// Inject element at specific index in dynamic array
inject_at :: proc(arr: ^[dynamic]$T, index: int, value: T) {
    append(arr, value) // Add element at end first
    // Shift elements to the right
    for i := len(arr) - 1; i > index; i -= 1 {
        arr[i] = arr[i-1]
    }
    arr[index] = value
}

// Vertex hash for deduplication
Vertex_Hash :: struct {
    buckets: []int,
    chain:   [dynamic]int,
    values:  [dynamic][3]f32,
    count:   int,
}

vertex_hash_create :: proc(hash: ^Vertex_Hash, bucket_count: int, allocator := context.allocator) {
    hash.buckets = make([]int, bucket_count, allocator)
    slice.fill(hash.buckets, -1)
    hash.chain = make([dynamic]int, 0, allocator)
    hash.values = make([dynamic][3]f32, 0, allocator)
    hash.count = 0
}

vertex_hash_destroy :: proc(hash: ^Vertex_Hash) {
    delete(hash.buckets)
    delete(hash.chain)
    delete(hash.values)
}

vertex_hash_add :: proc(hash: ^Vertex_Hash, vertex: [3]f32, tolerance: f32) -> int {
    bucket := int(math.abs(i32(vertex.x*tolerance) + i32(vertex.y*tolerance)*73856093 + i32(vertex.z*tolerance)*19349663)) % len(hash.buckets)

    // Check if vertex already exists
    i := hash.buckets[bucket]
    for i != -1 {
        v := hash.values[i]
        if math.abs(v.x - vertex.x) < tolerance &&
           math.abs(v.y - vertex.y) < tolerance &&
           math.abs(v.z - vertex.z) < tolerance {
            return i
        }
        i = hash.chain[i]
    }

    // Add new vertex
    idx := hash.count
    hash.count += 1
    append(&hash.values, vertex)
    append(&hash.chain, hash.buckets[bucket])
    hash.buckets[bucket] = idx

    return idx
}

// Int pair for edge representation
Int_Pair :: struct {
    a, b: i32,
}

make_int_pair :: proc "contextless" (a, b: i32) -> Int_Pair {
    if a < b {
        return Int_Pair{a, b}
    }
    return Int_Pair{b, a}
}

int_pair_hash :: proc "contextless" (pair: Int_Pair) -> u32 {
    n := u32(pair.a) + u32(pair.b) << 16
    n = n ~ (n >> 2)
    n = n ~ (n >> 8)
    n = n + (n << 10)
    n = n ~ (n >> 5)
    n = n + (n << 8)
    n = n ~ (n >> 3)
    return n
}

// Get direction offsets for 4-connected grid
get_dir_offset_x :: proc "contextless" (dir: int) -> i32 {
    offset := [4]i32{-1, 0, 1, 0}
    return offset[dir & 0x03]
}

get_dir_offset_y :: proc "contextless" (dir: int) -> i32 {
    offset := [4]i32{0, 1, 0, -1}
    return offset[dir & 0x03]
}
