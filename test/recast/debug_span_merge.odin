package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_debug_span_merge_threshold :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{10, 10, 10}
    ok := recast.create_heightfield(hf, 10, 10, bmin, bmax, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Test flag merge threshold
    log.info("Adding first span: smin=10, smax=20, area=0 (RC_NULL_AREA)")
    ok = recast.add_span(hf, 5, 5, 10, 20, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")
    
    // Check what we have
    span := hf.spans[5 + 5 * hf.width]
    log.infof("After first span: smin=%d, smax=%d, area=%d", span.smin, span.smax, span.area)
    
    // Add span that overlaps but with smax difference > threshold
    log.info("Adding second span: smin=15, smax=30, area=63 (RC_WALKABLE_AREA)")
    log.infof("Expected merge check: |30 - 20| = 10 > 1 (threshold), so area should NOT merge")
    log.info("NOTE: This test expects different behavior than test_span_merge_threshold")
    ok = recast.add_span(hf, 5, 5, 15, 30, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")
    
    // Check result
    span = hf.spans[5 + 5 * hf.width]
    log.infof("After merge: smin=%d, smax=%d, area=%d", span.smin, span.smax, span.area)
    log.infof("Expected: smin=10, smax=30, area=63 (RC_WALKABLE_AREA)")
    
    // Area should not merge due to threshold (|30-20| = 10 > 1)
    // So it keeps the new span's area (63), not the old span's area (0)
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(30))
    testing.expect_value(t, span.area, u32(recast.RC_WALKABLE_AREA))
}