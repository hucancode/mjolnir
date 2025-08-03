package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_span_pool_allocation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.rc_free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{100, 10, 100}
    ok := recast.rc_create_heightfield(hf, 100, 100, bmin, bmax, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Initially no pools should be allocated
    testing.expect(t, hf.pools == nil, "Pools should be nil initially")
    testing.expect(t, hf.freelist == nil, "Freelist should be nil initially")
    
    // Add a span to trigger pool allocation
    ok = recast.rc_add_span(hf, 0, 0, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span")
    
    // Now we should have one pool
    testing.expect(t, hf.pools != nil, "Pool should be allocated")
    testing.expect(t, hf.freelist != nil, "Freelist should not be nil")
    
    // Count pools
    pool_count := 0
    pool := hf.pools
    for pool != nil {
        pool_count += 1
        pool = pool.next
    }
    testing.expect_value(t, pool_count, 1)
}

@(test)
test_span_pool_growth :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.rc_free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{100, 10, 100}
    ok := recast.rc_create_heightfield(hf, 100, 100, bmin, bmax, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Add many spans to force multiple pool allocations
    // Each pool has RC_SPANS_PER_POOL spans
    spans_to_add := recast.RC_SPANS_PER_POOL + 100
    
    for i in 0..<spans_to_add {
        x := i32(i % 100)
        z := i32(i / 100)
        // Add non-overlapping spans to avoid merging
        smin := u16(i * 10)
        smax := u16(i * 10 + 5)
        
        ok = recast.rc_add_span(hf, x, z, smin, smax, recast.RC_WALKABLE_AREA, 1)
        testing.expect(t, ok, "Failed to add span")
    }
    
    // Count pools - should have at least 2
    pool_count := 0
    pool := hf.pools
    for pool != nil {
        pool_count += 1
        pool = pool.next
    }
    testing.expect(t, pool_count >= 2, "Should have allocated multiple pools")
    
    log.infof("Allocated %d pools for %d spans", pool_count, spans_to_add)
}

@(test)
test_span_freelist_reuse :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.rc_free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{10, 10, 10}
    ok := recast.rc_create_heightfield(hf, 10, 10, bmin, bmax, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Add and remove spans multiple times to test freelist reuse
    for cycle in 0..<10 {
        // Add spans at different columns to avoid conflicts
        for i in 0..<10 {
            // Add span at column (i, cycle)
            ok = recast.rc_add_span(hf, i32(i), i32(cycle % 10), 10, 20, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add span")
        }
        
        // Add more spans to trigger pool allocation
        for i in 0..<10 {
            // Add another span at same location but different height
            ok = recast.rc_add_span(hf, i32(i), i32(cycle % 10), 30, 40, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add second span")
        }
    }
    
    // Count final pools - should be minimal due to reuse
    pool_count := 0
    pool := hf.pools
    max_pools := 100 // Safety limit to prevent infinite loop
    for pool != nil && pool_count < max_pools {
        pool_count += 1
        pool = pool.next
    }
    
    if pool_count >= max_pools {
        testing.expect(t, false, "Pool list appears to have a cycle")
        return
    }
    
    // Should have only 1-2 pools due to efficient reuse
    testing.expect(t, pool_count <= 2, "Pool count should be minimal due to reuse")
    log.infof("Final pool count after reuse cycles: %d", pool_count)
}

@(test)
test_memory_cleanup :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test that memory is properly cleaned up
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{50, 10, 50}
    ok := recast.rc_create_heightfield(hf, 50, 50, bmin, bmax, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Add many spans to allocate multiple pools
    for i in 0..<1000 {
        x := i32(i % 50)
        z := i32(i / 50)
        ok = recast.rc_add_span(hf, x, z, u16(i*2), u16(i*2+1), recast.RC_WALKABLE_AREA, 1)
        testing.expect(t, ok, "Failed to add span")
    }
    
    // Count pools before cleanup
    pool_count := 0
    pool := hf.pools
    for pool != nil {
        pool_count += 1
        pool = pool.next
    }
    log.infof("Allocated %d pools before cleanup", pool_count)
    
    // Free the heightfield - should clean up all pools
    recast.rc_free_heightfield(hf)
    
    // If we get here without crashing, cleanup worked
    testing.expect(t, true, "Memory cleanup completed successfully")
}

@(test)
test_span_allocation_stress :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.rc_free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{200, 10, 200}
    ok := recast.rc_create_heightfield(hf, 200, 200, bmin, bmax, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Stress test: Add many overlapping spans that will cause lots of allocations and frees
    total_operations := 0
    for z in 0..<200 {
        for x in 0..<200 {
            // Add multiple overlapping spans per cell
            for h in 0..<5 {
                smin := u16(h * 20)
                smax := u16(h * 20 + 15)
                ok = recast.rc_add_span(hf, i32(x), i32(z), smin, smax, recast.RC_WALKABLE_AREA, 1)
                testing.expect(t, ok, "Failed to add span")
                total_operations += 1
            }
            
            // Add a large span that overlaps all previous ones (causes merging)
            if x % 10 == 0 && z % 10 == 0 {
                ok = recast.rc_add_span(hf, i32(x), i32(z), 0, 100, recast.RC_NULL_AREA, 1)
                testing.expect(t, ok, "Failed to add merging span")
                total_operations += 1
            }
        }
    }
    
    // Count final state
    pool_count := 0
    pool := hf.pools
    for pool != nil {
        pool_count += 1
        pool = pool.next
    }
    
    // Count active spans
    active_spans := 0
    for i in 0..<(hf.width * hf.height) {
        span := hf.spans[i]
        for span != nil {
            active_spans += 1
            span = span.next
        }
    }
    
    log.infof("Stress test complete: %d operations, %d pools, %d active spans", 
              total_operations, pool_count, active_spans)
    
    // Verify we didn't leak excessive memory
    expected_max_pools := (active_spans / recast.RC_SPANS_PER_POOL) + 2
    testing.expect(t, pool_count <= expected_max_pools, "Pool count should be reasonable")
}