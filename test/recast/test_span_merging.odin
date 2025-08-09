package test_recast

import "core:testing"
import "core:log"
import "core:time"
import nav "../../mjolnir/navigation/recast"

// Test span merging behavior - validates merging algorithm correctness
@(test)
test_span_merging_with_flag_threshold :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create a small heightfield for testing
    hf: nav.Heightfield
    success := nav.create_heightfield(&hf, 10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.2)
    testing.expect(t, success, "Failed to create heightfield")
    defer nav.free_heightfield(&hf)
    
    // Test case 1: Merging spans with area flag threshold
    // Add first span with area 1
    success = nav.add_span(&hf, 5, 5, 10, 20, 1, 2)
    testing.expect(t, success, "Failed to add first span")
    
    // Add overlapping span with area 2, within merge threshold
    // Original span: smax=20, new span: smax=21
    // Difference = |20-21| = 1, which is <= threshold of 2
    // Should merge and take max area (2)
    success = nav.add_span(&hf, 5, 5, 15, 21, 2, 2)
    testing.expect(t, success, "Failed to add second span")
    
    // Check result - should have one merged span
    span := hf.spans[5 + 5 * hf.width]
    testing.expect(t, span != nil, "No span at expected location")
    if span != nil {
        testing.expect_value(t, span.smin, u32(10))
        testing.expect_value(t, span.smax, u32(21))
        testing.expect_value(t, span.area, u32(2)) // Should take max area
        testing.expect(t, span.next == nil, "Should have no next span after merge")
    }
    
    // Test case 2: Spans outside merge threshold
    // Clear the column
    for s := hf.spans[5 + 5 * hf.width]; s != nil; {
        next := s.next
        nav.free_span(&hf, s)
        s = next
    }
    hf.spans[5 + 5 * hf.width] = nil
    
    // Add first span
    success = nav.add_span(&hf, 5, 5, 10, 20, 1, 2)
    testing.expect(t, success, "Failed to add first span for test 2")
    
    // Add overlapping span with area 2, OUTSIDE merge threshold
    // Original span: smax=20, new span: smax=24
    // Difference = |20-24| = 4, which is > threshold of 2
    // Should merge bounds but keep area based on algorithm
    success = nav.add_span(&hf, 5, 5, 15, 24, 2, 2)
    testing.expect(t, success, "Failed to add second span for test 2")
    
    span = hf.spans[5 + 5 * hf.width]
    testing.expect(t, span != nil, "No span at expected location for test 2")
    if span != nil {
        testing.expect_value(t, span.smin, u32(10))
        testing.expect_value(t, span.smax, u32(24))
        // With the fix, area merging happens only when ORIGINAL smaxes are within threshold
        // Since |20-24| > 2, areas should NOT be merged, so area stays as new span's area
        testing.expect_value(t, span.area, u32(2))
    }
    
    // Test case 3: Multiple overlapping spans
    // Clear the column again
    for s := hf.spans[5 + 5 * hf.width]; s != nil; {
        next := s.next
        nav.free_span(&hf, s)
        s = next
    }
    hf.spans[5 + 5 * hf.width] = nil
    
    // Add three overlapping spans that should all merge
    success = nav.add_span(&hf, 5, 5, 10, 15, 1, 5)
    testing.expect(t, success, "Failed to add span 1 for test 3")
    
    success = nav.add_span(&hf, 5, 5, 12, 18, 2, 5)
    testing.expect(t, success, "Failed to add span 2 for test 3")
    
    success = nav.add_span(&hf, 5, 5, 14, 20, 3, 5)
    testing.expect(t, success, "Failed to add span 3 for test 3")
    
    // Should have one merged span covering the full range
    span = hf.spans[5 + 5 * hf.width]
    testing.expect(t, span != nil, "No span at expected location for test 3")
    if span != nil {
        testing.expect_value(t, span.smin, u32(10))
        testing.expect_value(t, span.smax, u32(20))
        // Area should be max of all merged spans when within threshold
        testing.expect_value(t, span.area, u32(3))
        testing.expect(t, span.next == nil, "Should have single merged span")
    }
    
    log.info("✓ Span merging test completed successfully")
}