package navigation_recast

import "core:slice"
import "core:math"
import "core:math/linalg"

// Get offset of a tile in the tile grid
calc_tile_loc :: proc "contextless" (x, y: i32) -> u32 {
    return u32(x) & 0x0000ffff | (u32(y) & 0x0000ffff) << 16
}

// Calculate grid location from position
calc_grid_location :: proc "contextless" (pos: [3]f32, cell_size: f32) -> (x, y: i32) {
    grid_pos := linalg.floor(pos.xz / cell_size)
    return i32(grid_pos.x), i32(grid_pos.y)
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
    resize(arr, len(arr) + 1)  // Expand slice
    copy(arr[index+1:], arr[index:len(arr)-1])  // Shift elements right
    arr[index] = value  // Insert new value
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
