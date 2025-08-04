package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"

@(test)
test_span_allocation :: proc(t: ^testing.T) {

    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    // Create a small heightfield
    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Test adding a single span
    ok = recast.add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span should succeed")

    // Check that the span was added
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Span should exist")
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(20))
    testing.expect_value(t, span.area, u32(nav_recast.RC_WALKABLE_AREA))
    testing.expect(t, span.next == nil, "Should be only span in column")
}

@(test)
test_span_merging :: proc(t: ^testing.T) {

    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add first span
    ok = recast.add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding first span should succeed")

    // Add overlapping span (should merge)
    ok = recast.add_span(hf, 5, 5, 15, 25, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding overlapping span should succeed")

    // Check that spans were merged
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Merged span should exist")
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(25))
    testing.expect(t, span.next == nil, "Should still be only one span after merge")
}

@(test)
test_span_non_overlapping :: proc(t: ^testing.T) {

    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add first span
    ok = recast.add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding first span should succeed")

    // Add non-overlapping span (should create new span)
    ok = recast.add_span(hf, 5, 5, 30, 40, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding non-overlapping span should succeed")

    // Check that we have two separate spans
    column_index := 5 + 5 * hf.width
    span1 := hf.spans[column_index]
    testing.expect(t, span1 != nil, "First span should exist")
    testing.expect_value(t, span1.smin, u32(10))
    testing.expect_value(t, span1.smax, u32(20))

    span2 := span1.next
    testing.expect(t, span2 != nil, "Second span should exist")
    testing.expect_value(t, span2.smin, u32(30))
    testing.expect_value(t, span2.smax, u32(40))
    testing.expect(t, span2.next == nil, "Should be last span")
}

@(test)
test_span_area_priority :: proc(t: ^testing.T) {

    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add span with lower priority area
    ok = recast.add_span(hf, 5, 5, 10, 20, 10, 1)
    testing.expect(t, ok, "Adding first span should succeed")

    // Add overlapping span with higher priority area
    ok = recast.add_span(hf, 5, 5, 15, 25, 20, 1)
    testing.expect(t, ok, "Adding higher priority span should succeed")

    // Check that the higher priority area was preserved
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Merged span should exist")
    testing.expect_value(t, span.area, u32(20))
}

@(test)
test_span_debug_merge :: proc(t: ^testing.T) {
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 1, 1, {0,0,0}, {1,1,1}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add three separate spans at (0,0)
    ok = recast.add_span(hf, 0, 0, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 1 should succeed")
    
    ok = recast.add_span(hf, 0, 0, 30, 40, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 2 should succeed")
    
    ok = recast.add_span(hf, 0, 0, 50, 60, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 3 should succeed")
    
    // Print current state
    log.info("Before merge:")
    span := hf.spans[0]
    i := 0
    for span != nil && i < 5 {
        log.infof("  Span %d: [%d-%d]", i, span.smin, span.smax)
        span = span.next
        i += 1
    }
    
    // Add bridging span
    ok = recast.add_span(hf, 0, 0, 15, 35, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding bridging span should succeed")
    
    // Print result
    log.info("After merge:")
    span = hf.spans[0]
    i = 0
    for span != nil && i < 5 {
        log.infof("  Span %d: [%d-%d]", i, span.smin, span.smax)
        span = span.next
        i += 1
    }
    
    // Check result
    span = hf.spans[0]
    testing.expect(t, span != nil)
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(40))
    
    span = span.next
    testing.expect(t, span != nil)
    testing.expect_value(t, span.smin, u32(50))
    testing.expect_value(t, span.smax, u32(60))
    
    testing.expect(t, span.next == nil)
}

@(test)
test_span_simple_merge :: proc(t: ^testing.T) {
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add two separate spans
    ok = recast.add_span(hf, 0, 0, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 1 should succeed")

    ok = recast.add_span(hf, 0, 0, 30, 40, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 2 should succeed")

    // Check we have two spans
    span := hf.spans[0]
    testing.expect(t, span != nil, "First span should exist")
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(20))
    
    span = span.next
    testing.expect(t, span != nil, "Second span should exist")
    testing.expect_value(t, span.smin, u32(30))
    testing.expect_value(t, span.smax, u32(40))
    testing.expect(t, span.next == nil, "Should be last span")
}

@(test)
test_span_multiple_columns :: proc(t: ^testing.T) {

    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add spans in different columns
    for x in 0..<5 {
        for z in 0..<5 {
            ok = recast.add_span(hf, i32(x), i32(z), u16(x*10), u16(x*10+10), nav_recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Adding span should succeed")
        }
    }

    // Verify spans were added correctly
    for x in 0..<5 {
        for z in 0..<5 {
            column_index := i32(x) + i32(z) * hf.width
            span := hf.spans[column_index]
            testing.expect(t, span != nil, "Span should exist")
            testing.expect_value(t, span.smin, u32(x*10))
            testing.expect_value(t, span.smax, u32(x*10+10))
        }
    }
}

@(test)
test_span_complex_merging :: proc(t: ^testing.T) {

    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Create a complex scenario with multiple overlapping spans
    // Add spans: [10-20], [30-40], [50-60]
    ok = recast.add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 1 should succeed")
    log.info("Added span [10-20]")

    ok = recast.add_span(hf, 5, 5, 30, 40, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 2 should succeed")
    log.info("Added span [30-40]")

    ok = recast.add_span(hf, 5, 5, 50, 60, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 3 should succeed")
    log.info("Added span [50-60]")

    // Debug: print spans before bridging
    log.info("Spans before bridging:")
    {
        s := hf.spans[5 + 5 * hf.width]
        c := 0
        for s != nil && c < 5 {
            log.infof("  Span %d: [%d-%d]", c, s.smin, s.smax)
            s = s.next
            c += 1
        }
    }
    
    // Add a span that bridges the gap between first two: [15-35]
    ok = recast.add_span(hf, 5, 5, 15, 35, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding bridging span should succeed")
    log.info("Added bridging span [15-35]")

    // Debug: Check what happened to [50-60]
    log.info("Checking all columns for [50-60] span:")
    for i in 0..<10 {
        for j in 0..<10 {
            s := hf.spans[i + j * int(hf.width)]
            if s != nil && s.smin == 50 && s.smax == 60 {
                log.infof("Found [50-60] at column (%d,%d)", i, j)
            }
        }
    }
    
    // Should now have two spans: [10-40] and [50-60]
    column_index := 5 + 5 * hf.width
    span1 := hf.spans[column_index]
    testing.expect(t, span1 != nil, "First merged span should exist")
    
    // Debug: print all spans
    log.info("Spans after merging:")
    span := span1
    count := 0
    for span != nil && count < 10 {
        log.infof("  Span %d: [%d-%d] area=%d", count, span.smin, span.smax, span.area)
        span = span.next
        count += 1
    }
    
    testing.expect_value(t, span1.smin, u32(10))
    testing.expect_value(t, span1.smax, u32(40))

    span2 := span1.next
    testing.expect(t, span2 != nil, "Second span should exist")
    testing.expect_value(t, span2.smin, u32(50))
    testing.expect_value(t, span2.smax, u32(60))
    testing.expect(t, span2.next == nil, "Should be last span")
}
