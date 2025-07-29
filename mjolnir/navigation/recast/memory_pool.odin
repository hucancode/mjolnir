package navigation_recast

import "core:mem"
import "core:log"
import "core:sync"

// Navigation-specific memory pools for high-performance allocation patterns
Nav_Memory_Pool :: struct {
    // Small object pools for frequent allocations
    small_blocks:     Pool_Allocator,     // 32-256 bytes
    medium_blocks:    Pool_Allocator,     // 256-2KB
    large_blocks:     Pool_Allocator,     // 2KB-32KB

    // Specialized pools for navigation data structures
    poly_refs_pool:   Array_Pool(Poly_Ref),      // Polygon reference arrays
    vertices_pool:    Array_Pool([3]f32),        // Vertex arrays
    indices_pool:     Array_Pool(i32),           // Index arrays
    stack_pool:       Array_Pool(i32),           // Stack arrays for algorithms

    // Temporary allocator arena for short-lived allocations
    temp_arena:       mem.Arena,
    temp_buffer:      []u8,

    // Statistics and monitoring
    stats:            Pool_Stats,
    mutex:            sync.Mutex,
}

// Pool allocator for fixed-size blocks
Pool_Allocator :: struct {
    block_size:       int,
    blocks_per_chunk: int,
    free_blocks:      [dynamic]rawptr,
    chunks:           [dynamic][]u8,
    total_allocated:  int,
    peak_usage:       int,
}

// Array pool for dynamic arrays of specific types
Array_Pool :: struct($T: typeid) {
    small_arrays:     [dynamic][dynamic]T,     // 8-64 elements
    medium_arrays:    [dynamic][dynamic]T,     // 64-512 elements
    large_arrays:     [dynamic][dynamic]T,     // 512+ elements

    small_free:       [dynamic]int,            // Indices of free small arrays
    medium_free:      [dynamic]int,            // Indices of free medium arrays
    large_free:       [dynamic]int,            // Indices of free large arrays
}

// Memory pool statistics
Pool_Stats :: struct {
    small_allocs:     u64,
    medium_allocs:    u64,
    large_allocs:     u64,
    array_allocs:     u64,
    temp_allocs:      u64,

    total_bytes:      u64,
    peak_bytes:       u64,

    cache_hits:       u64,
    cache_misses:     u64,
}

// Configuration for memory pool sizes
Nav_Pool_Config :: struct {
    small_block_size:     int,    // Default: 256 bytes
    medium_block_size:    int,    // Default: 2KB
    large_block_size:     int,    // Default: 32KB

    blocks_per_chunk:     int,    // Default: 64
    temp_arena_size:      int,    // Default: 1MB

    enable_statistics:    bool,   // Default: true
}

// Default configuration optimized for navigation workloads
NAV_POOL_DEFAULT_CONFIG :: Nav_Pool_Config{
    small_block_size  = 256,
    medium_block_size = 2048,
    large_block_size  = 32768,
    blocks_per_chunk  = 64,
    temp_arena_size   = 1024 * 1024,  // 1MB
    enable_statistics = true,
}

// Initialize navigation memory pool
nav_pool_init :: proc(pool: ^Nav_Memory_Pool, config: Nav_Pool_Config = NAV_POOL_DEFAULT_CONFIG) {
    pool.mutex = {}

    // Initialize block pools
    pool_allocator_init(&pool.small_blocks, config.small_block_size, config.blocks_per_chunk)
    pool_allocator_init(&pool.medium_blocks, config.medium_block_size, config.blocks_per_chunk)
    pool_allocator_init(&pool.large_blocks, config.large_block_size, config.blocks_per_chunk)

    // Initialize array pools
    array_pool_init(&pool.poly_refs_pool)
    array_pool_init(&pool.vertices_pool)
    array_pool_init(&pool.indices_pool)
    array_pool_init(&pool.stack_pool)

    // Initialize temp arena
    pool.temp_buffer = make([]u8, config.temp_arena_size)
    mem.arena_init(&pool.temp_arena, pool.temp_buffer)

    log.infof("Navigation memory pool initialized (temp arena: %d bytes)", config.temp_arena_size)
}

// Destroy navigation memory pool
nav_pool_destroy :: proc(pool: ^Nav_Memory_Pool) {
    sync.mutex_lock(&pool.mutex)
    defer sync.mutex_unlock(&pool.mutex)

    // Clean up block pools
    pool_allocator_destroy(&pool.small_blocks)
    pool_allocator_destroy(&pool.medium_blocks)
    pool_allocator_destroy(&pool.large_blocks)

    // Clean up array pools
    array_pool_destroy(&pool.poly_refs_pool)
    array_pool_destroy(&pool.vertices_pool)
    array_pool_destroy(&pool.indices_pool)
    array_pool_destroy(&pool.stack_pool)

    // Clean up temp arena
    delete(pool.temp_buffer)

    log.infof("Navigation memory pool destroyed (peak usage: %d bytes)", pool.stats.peak_bytes)
}

// Allocate from appropriate pool based on size
nav_pool_alloc :: proc(pool: ^Nav_Memory_Pool, size: int, alignment: int = 8) -> rawptr {
    sync.mutex_lock(&pool.mutex)
    defer sync.mutex_unlock(&pool.mutex)

    pool.stats.total_bytes += u64(size)
    if pool.stats.total_bytes > pool.stats.peak_bytes {
        pool.stats.peak_bytes = pool.stats.total_bytes
    }

    // Choose appropriate pool based on size
    if size <= pool.small_blocks.block_size {
        pool.stats.small_allocs += 1
        return pool_allocator_alloc(&pool.small_blocks)
    }
    if size <= pool.medium_blocks.block_size {
        pool.stats.medium_allocs += 1
        return pool_allocator_alloc(&pool.medium_blocks)
    }
    if size <= pool.large_blocks.block_size {
        pool.stats.large_allocs += 1
        return pool_allocator_alloc(&pool.large_blocks)
    }
    // Fallback to system allocator for very large allocations
    ptr, _ := mem.alloc(size, alignment)
    return ptr
}

// Free memory back to appropriate pool
nav_pool_free :: proc(pool: ^Nav_Memory_Pool, ptr: rawptr, size: int) {
    if ptr == nil do return

    sync.mutex_lock(&pool.mutex)
    defer sync.mutex_unlock(&pool.mutex)

    pool.stats.total_bytes -= u64(size)

    // Return to appropriate pool based on size
    when true {
        if size <= pool.small_blocks.block_size {
            pool_allocator_free(&pool.small_blocks, ptr)
        } else if size <= pool.medium_blocks.block_size {
            pool_allocator_free(&pool.medium_blocks, ptr)
        } else if size <= pool.large_blocks.block_size {
            pool_allocator_free(&pool.large_blocks, ptr)
        } else {
            // Fallback: free using system allocator
            mem.free(ptr)
        }
    }
}

// Get temporary allocator for short-lived allocations
nav_pool_temp_allocator :: proc(pool: ^Nav_Memory_Pool) -> mem.Allocator {
    return mem.arena_allocator(&pool.temp_arena)
}

// Reset temporary arena (call at end of frame/operation)
nav_pool_reset_temp :: proc(pool: ^Nav_Memory_Pool) {
    sync.mutex_lock(&pool.mutex)
    defer sync.mutex_unlock(&pool.mutex)

    mem.arena_free_all(&pool.temp_arena)
}

// Get array from pool (automatically sized)
nav_pool_get_array :: proc(pool: ^Nav_Memory_Pool, $T: typeid, capacity: int) -> ^[dynamic]T {
    sync.mutex_lock(&pool.mutex)
    defer sync.mutex_unlock(&pool.mutex)

    when T == Poly_Ref {
        return array_pool_get(&pool.poly_refs_pool, capacity)
    } else when T == [3]f32 {
        return array_pool_get(&pool.vertices_pool, capacity)
    } else when T == i32 {
        return array_pool_get(&pool.indices_pool, capacity)
    } else {
        // Fallback: allocate new array
        arr := new([dynamic]T)
        reserve(arr, capacity)
        return arr
    }
}

// Return array to pool
nav_pool_return_array :: proc(pool: ^Nav_Memory_Pool, array: ^[dynamic]$T) {
    if array == nil do return

    sync.mutex_lock(&pool.mutex)
    defer sync.mutex_unlock(&pool.mutex)

    when T == Poly_Ref {
        array_pool_return(&pool.poly_refs_pool, array)
    } else when T == [3]f32 {
        array_pool_return(&pool.vertices_pool, array)
    } else when T == i32 {
        array_pool_return(&pool.indices_pool, array)
    } else {
        // Fallback: just free it
        delete(array^)
        free(array)
    }
}

// Get pool statistics
nav_pool_get_stats :: proc(pool: ^Nav_Memory_Pool) -> Pool_Stats {
    sync.mutex_lock(&pool.mutex)
    defer sync.mutex_unlock(&pool.mutex)

    return pool.stats
}

// Print pool statistics
nav_pool_print_stats :: proc(pool: ^Nav_Memory_Pool) {
    stats := nav_pool_get_stats(pool)

    log.infof("Navigation Memory Pool Statistics:")
    log.infof("  Small allocs:  %d", stats.small_allocs)
    log.infof("  Medium allocs: %d", stats.medium_allocs)
    log.infof("  Large allocs:  %d", stats.large_allocs)
    log.infof("  Array allocs:  %d", stats.array_allocs)
    log.infof("  Temp allocs:   %d", stats.temp_allocs)
    log.infof("  Total bytes:   %d", stats.total_bytes)
    log.infof("  Peak bytes:    %d", stats.peak_bytes)
    log.infof("  Cache hits:    %d", stats.cache_hits)
    log.infof("  Cache misses:  %d", stats.cache_misses)

    hit_ratio := f32(stats.cache_hits) / f32(stats.cache_hits + stats.cache_misses) * 100.0
    log.infof("  Cache hit ratio: %.1f%%", hit_ratio)
}

// Private implementation details

@(private)
pool_allocator_init :: proc(pool: ^Pool_Allocator, block_size: int, blocks_per_chunk: int) {
    pool.block_size = block_size
    pool.blocks_per_chunk = blocks_per_chunk
    pool.free_blocks = make([dynamic]rawptr)
    pool.chunks = make([dynamic][]u8)
}

@(private)
pool_allocator_destroy :: proc(pool: ^Pool_Allocator) {
    for chunk in pool.chunks {
        delete(chunk)
    }
    delete(pool.chunks)
    delete(pool.free_blocks)
}

@(private)
pool_allocator_alloc :: proc(pool: ^Pool_Allocator) -> rawptr {
    if len(pool.free_blocks) == 0 {
        // Allocate new chunk
        chunk_size := pool.block_size * pool.blocks_per_chunk
        chunk := make([]u8, chunk_size)
        append(&pool.chunks, chunk)

        // Add all blocks from chunk to free list
        for i in 0..<pool.blocks_per_chunk {
            block := raw_data(chunk[i * pool.block_size:])
            append(&pool.free_blocks, block)
        }

        pool.total_allocated += chunk_size
        if pool.total_allocated > pool.peak_usage {
            pool.peak_usage = pool.total_allocated
        }
    }

    // Return block from free list
    block := pop(&pool.free_blocks)
    return block
}

@(private)
pool_allocator_free :: proc(pool: ^Pool_Allocator, ptr: rawptr) {
    append(&pool.free_blocks, ptr)
}

@(private)
array_pool_init :: proc(pool: ^Array_Pool($T)) {
    pool.small_arrays = make([dynamic][dynamic]T)
    pool.medium_arrays = make([dynamic][dynamic]T)
    pool.large_arrays = make([dynamic][dynamic]T)

    pool.small_free = make([dynamic]int)
    pool.medium_free = make([dynamic]int)
    pool.large_free = make([dynamic]int)
}

@(private)
array_pool_destroy :: proc(pool: ^Array_Pool($T)) {
    for &arr in pool.small_arrays do delete(arr)
    for &arr in pool.medium_arrays do delete(arr)
    for &arr in pool.large_arrays do delete(arr)

    delete(pool.small_arrays)
    delete(pool.medium_arrays)
    delete(pool.large_arrays)
    delete(pool.small_free)
    delete(pool.medium_free)
    delete(pool.large_free)
}

@(private)
array_pool_get :: proc(pool: ^Array_Pool($T), capacity: int) -> ^[dynamic]T {
    if capacity <= 64 {
        if len(pool.small_free) > 0 {
            idx := pop(&pool.small_free)
            arr := &pool.small_arrays[idx]
            clear(arr)
            reserve(arr, capacity)
            return arr
        } else {
            arr := make([dynamic]T, 0, capacity)
            append(&pool.small_arrays, arr)
            return &pool.small_arrays[len(pool.small_arrays) - 1]
        }
    } else if capacity <= 512 {
        if len(pool.medium_free) > 0 {
            idx := pop(&pool.medium_free)
            arr := &pool.medium_arrays[idx]
            clear(arr)
            reserve(arr, capacity)
            return arr
        } else {
            arr := make([dynamic]T, 0, capacity)
            append(&pool.medium_arrays, arr)
            return &pool.medium_arrays[len(pool.medium_arrays) - 1]
        }
    } else {
        if len(pool.large_free) > 0 {
            idx := pop(&pool.large_free)
            arr := &pool.large_arrays[idx]
            clear(arr)
            reserve(arr, capacity)
            return arr
        } else {
            arr := make([dynamic]T, 0, capacity)
            append(&pool.large_arrays, arr)
            return &pool.large_arrays[len(pool.large_arrays) - 1]
        }
    }
}

@(private)
array_pool_return :: proc(pool: ^Array_Pool($T), array: ^[dynamic]T) {
    capacity := cap(array^)

    // Find which pool this array belongs to
    if capacity <= 64 {
        for &arr, i in pool.small_arrays {
            if &arr == array {
                append(&pool.small_free, i)
                return
            }
        }
    } else if capacity <= 512 {
        for &arr, i in pool.medium_arrays {
            if &arr == array {
                append(&pool.medium_free, i)
                return
            }
        }
    } else {
        for &arr, i in pool.large_arrays {
            if &arr == array {
                append(&pool.large_free, i)
                return
            }
        }
    }
}

// Navigation-specific allocator interface
Nav_Allocator :: struct {
    pool: ^Nav_Memory_Pool,
}

nav_allocator :: proc(pool: ^Nav_Memory_Pool) -> mem.Allocator {
    return mem.Allocator{
        procedure = nav_allocator_proc,
        data = rawptr(pool),
    }
}

@(private)
nav_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                          size, alignment: int, old_memory: rawptr, old_size: int,
                          location := #caller_location) -> ([]u8, mem.Allocator_Error) {

    pool := cast(^Nav_Memory_Pool)allocator_data

    #partial switch mode {
    case .Alloc:
        ptr := nav_pool_alloc(pool, size, alignment)
        if ptr == nil do return nil, .Out_Of_Memory
        return mem.byte_slice(ptr, size), .None

    case .Free:
        nav_pool_free(pool, old_memory, old_size)
        return nil, .None

    case .Free_All:
        // Not supported for pools
        return nil, .Mode_Not_Implemented

    case .Resize:
        // Simple implementation: allocate new, copy, free old
        if size == 0 {
            nav_pool_free(pool, old_memory, old_size)
            return nil, .None
        }

        new_ptr := nav_pool_alloc(pool, size, alignment)
        if new_ptr == nil do return nil, .Out_Of_Memory

        if old_memory != nil {
            copy_size := min(old_size, size)
            mem.copy(new_ptr, old_memory, copy_size)
            nav_pool_free(pool, old_memory, old_size)
        }

        return mem.byte_slice(new_ptr, size), .None

    case .Query_Features:
        set := mem.Allocator_Mode_Set{.Alloc, .Free, .Resize}
        return mem.byte_slice(&set, size_of(mem.Allocator_Mode_Set)), .None

    case .Query_Info:
        return nil, .Mode_Not_Implemented
    }

    return nil, .Mode_Not_Implemented
}
