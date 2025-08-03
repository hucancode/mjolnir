package navigation_recast

import "core:sync"
import "base:intrinsics"
import "core:mem"
import "core:log"

// Lock-free memory pool using atomic operations
Lockfree_Pool :: struct {
    // Memory chunks
    chunks:           [dynamic][]u8,
    chunk_size:       int,
    block_size:       int,
    blocks_per_chunk: int,
    
    // Lock-free free list using atomic CAS
    free_list_head:   ^Lockfree_Node,
    
    // Statistics (atomic)
    allocated_count:  i64,
    freed_count:      i64,
    chunk_count:      i64,
}

// Node for lock-free linked list
Lockfree_Node :: struct {
    next: ^Lockfree_Node,
}

// Initialize lock-free pool
lockfree_pool_init :: proc(pool: ^Lockfree_Pool, block_size: int, blocks_per_chunk: int) {
    pool.block_size = block_size
    pool.blocks_per_chunk = blocks_per_chunk
    pool.chunk_size = block_size * blocks_per_chunk
    pool.chunks = make([dynamic][]u8)
    pool.free_list_head = nil
    
    // Pre-allocate first chunk
    lockfree_pool_grow(pool)
}

// Grow pool by adding new chunk
lockfree_pool_grow :: proc(pool: ^Lockfree_Pool) {
    chunk := make([]u8, pool.chunk_size)
    append(&pool.chunks, chunk)
    
    // Add all blocks to free list
    for i := 0; i < pool.blocks_per_chunk; i += 1 {
        block := cast(^Lockfree_Node)&chunk[i * pool.block_size]
        
        // Atomic push to free list
        for {
            old_head := intrinsics.atomic_load(&pool.free_list_head)
            block.next = old_head
            if _, ok := intrinsics.atomic_compare_exchange_strong(&pool.free_list_head, old_head, block); ok {
                break
            }
        }
    }
    
    intrinsics.atomic_add(&pool.chunk_count, 1)
}

// Allocate from pool (lock-free)
lockfree_pool_alloc :: proc(pool: ^Lockfree_Pool) -> rawptr {
    for {
        // Try to pop from free list
        head := intrinsics.atomic_load(&pool.free_list_head)
        if head == nil {
            // Need to grow pool
            lockfree_pool_grow(pool)
            continue
        }
        
        next := head.next
        if _, ok := intrinsics.atomic_compare_exchange_strong(&pool.free_list_head, head, next); ok {
            intrinsics.atomic_add(&pool.allocated_count, 1)
            return rawptr(head)
        }
    }
}

// Free to pool (lock-free)
lockfree_pool_free :: proc(pool: ^Lockfree_Pool, ptr: rawptr) {
    if ptr == nil do return
    
    node := cast(^Lockfree_Node)ptr
    
    // Atomic push to free list
    for {
        old_head := intrinsics.atomic_load(&pool.free_list_head)
        node.next = old_head
        if _, ok := intrinsics.atomic_compare_exchange_strong(&pool.free_list_head, old_head, node); ok {
            intrinsics.atomic_add(&pool.freed_count, 1)
            break
        }
    }
}

// Destroy lock-free pool
lockfree_pool_destroy :: proc(pool: ^Lockfree_Pool) {
    for chunk in pool.chunks {
        delete(chunk)
    }
    delete(pool.chunks)
}

// SIMD-optimized memory operations for bulk processing
SIMD_Memory_Ops :: struct {
    alignment: int,
}

// Fast memory clear using SIMD
@(optimization_mode="favor_size")
simd_clear_memory :: proc(ptr: rawptr, size: int) {
    // Align to 16-byte boundary for SSE
    aligned_ptr := uintptr(ptr)
    alignment_offset := int(16 - (aligned_ptr & 15)) & 15
    
    // Clear unaligned prefix
    if alignment_offset > 0 {
        mem.set(ptr, 0, alignment_offset)
    }
    
    // SIMD clear for aligned portion
    simd_ptr := rawptr(aligned_ptr + uintptr(alignment_offset))
    simd_size := (size - alignment_offset) & ~int(15)  // Round down to 16-byte chunks
    
    // Use intrinsics for fast clearing
    when ODIN_ARCH == .amd64 {
        // Would use SSE/AVX intrinsics here
        // For now, use optimized memset
        mem.set(simd_ptr, 0, simd_size)
    } else {
        mem.set(simd_ptr, 0, simd_size)
    }
    
    // Clear remaining bytes
    remaining_offset := alignment_offset + simd_size
    if remaining_offset < size {
        remaining_ptr := rawptr(uintptr(ptr) + uintptr(remaining_offset))
        mem.set(remaining_ptr, 0, size - remaining_offset)
    }
}

// Bulk allocation helper
Bulk_Allocator :: struct {
    pool:             ^Lockfree_Pool,
    allocated_blocks: [dynamic]rawptr,
    block_count:      int,
}

// Allocate multiple blocks at once
bulk_alloc :: proc(allocator: ^Bulk_Allocator, count: int) -> []rawptr {
    if count <= 0 do return nil
    
    // Ensure capacity
    if cap(allocator.allocated_blocks) < len(allocator.allocated_blocks) + count {
        reserve(&allocator.allocated_blocks, len(allocator.allocated_blocks) + count)
    }
    
    start_idx := len(allocator.allocated_blocks)
    
    // Allocate blocks
    for i := 0; i < count; i += 1 {
        block := lockfree_pool_alloc(allocator.pool)
        if block == nil {
            // Rollback on failure
            for j := start_idx; j < len(allocator.allocated_blocks); j += 1 {
                lockfree_pool_free(allocator.pool, allocator.allocated_blocks[j])
            }
            resize(&allocator.allocated_blocks, start_idx)
            return nil
        }
        append(&allocator.allocated_blocks, block)
    }
    
    allocator.block_count += count
    return allocator.allocated_blocks[start_idx:]
}

// Free all allocated blocks
bulk_free_all :: proc(allocator: ^Bulk_Allocator) {
    for block in allocator.allocated_blocks {
        lockfree_pool_free(allocator.pool, block)
    }
    clear(&allocator.allocated_blocks)
    allocator.block_count = 0
}

// Object pool for specific types with recycling
Object_Pool :: struct($T: typeid) {
    base_pool:    Lockfree_Pool,
    constructor:  proc(obj: ^T),
    destructor:   proc(obj: ^T),
    
    // Statistics
    active_count: i64,
    reuse_count:  i64,
}

// Initialize object pool
object_pool_init :: proc(pool: ^Object_Pool($T), initial_capacity: int = 64,
                        constructor: proc(obj: ^T) = nil,
                        destructor: proc(obj: ^T) = nil) {
    lockfree_pool_init(&pool.base_pool, size_of(T), initial_capacity)
    pool.constructor = constructor
    pool.destructor = destructor
}

// Get object from pool
object_pool_get :: proc(pool: ^Object_Pool($T)) -> ^T {
    ptr := lockfree_pool_alloc(&pool.base_pool)
    if ptr == nil do return nil
    
    obj := cast(^T)ptr
    
    // Clear memory
    simd_clear_memory(obj, size_of(T))
    
    // Call constructor if provided
    if pool.constructor != nil {
        pool.constructor(obj)
    }
    
    intrinsics.atomic_add(&pool.active_count, 1)
    return obj
}

// Return object to pool
object_pool_return :: proc(pool: ^Object_Pool($T), obj: ^T) {
    if obj == nil do return
    
    // Call destructor if provided
    if pool.destructor != nil {
        pool.destructor(obj)
    }
    
    lockfree_pool_free(&pool.base_pool, obj)
    intrinsics.atomic_sub(&pool.active_count, 1)
    intrinsics.atomic_add(&pool.reuse_count, 1)
}

// Destroy object pool
object_pool_destroy :: proc(pool: ^Object_Pool($T)) {
    lockfree_pool_destroy(&pool.base_pool)
}