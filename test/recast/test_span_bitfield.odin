package test_recast

import "core:testing"
import "core:log"
import navigation "../../mjolnir/navigation/recast"

@(test)
test_span_bitfield :: proc(t: ^testing.T) {
    using navigation

    log.info("Testing Span bit field behavior")
    
    // Create a span and test field assignments
    span: Span
    
    // Test setting smin
    span.smin = 100
    testing.expectf(t, span.smin == 100, "Expected smin=100, got %d", span.smin)
    
    // Test setting smax
    span.smax = 200
    testing.expectf(t, span.smax == 200, "Expected smax=200, got %d", span.smax)
    testing.expectf(t, span.smin == 100, "smin changed after setting smax! Got %d", span.smin)
    
    // Test setting area
    span.area = 63
    testing.expectf(t, span.area == 63, "Expected area=63, got %d", span.area)
    testing.expectf(t, span.smin == 100, "smin changed after setting area! Got %d", span.smin)
    testing.expectf(t, span.smax == 200, "smax changed after setting area! Got %d", span.smax)
    
    // Test max values for 13-bit fields
    span.smin = (1 << 13) - 1  // 8191
    span.smax = (1 << 13) - 1  // 8191
    testing.expectf(t, span.smin == 8191, "Expected smin=8191, got %d", span.smin)
    testing.expectf(t, span.smax == 8191, "Expected smax=8191, got %d", span.smax)
    
    // Test that compiler enforces max values
    // span.smin = 8192  // This would cause a compile error
    // Instead test with max valid value
    span.smin = 8191
    log.infof("smin after setting to 8191 (max): %d", span.smin)
    
    // Test typical rasterization values
    span.smin = 0
    span.smax = 11
    span.area = 63
    testing.expectf(t, span.smin == 0, "Expected smin=0, got %d", span.smin)
    testing.expectf(t, span.smax == 11, "Expected smax=11, got %d", span.smax)
    testing.expectf(t, span.area == 63, "Expected area=63, got %d", span.area)
    
    // Check the actual bit layout
    log.infof("Span with smin=0, smax=11, area=63: data=%032b", span.data)
    
    // Test another typical case
    span2: Span
    span2.smin = 10
    span2.smax = 11
    span2.area = 63
    testing.expectf(t, span2.smin == 10, "Expected smin=10, got %d", span2.smin)
    testing.expectf(t, span2.smax == 11, "Expected smax=11, got %d", span2.smax)
    testing.expectf(t, span2.area == 63, "Expected area=63, got %d", span2.area)
    
    log.infof("Span2 with smin=10, smax=11, area=63: data=%032b", span2.data)
}

@(test)
test_span_in_add_span :: proc(t: ^testing.T) {
    using navigation
    
    // Create a minimal heightfield
    hf := alloc_heightfield()
    defer free_heightfield(hf)
    
    init_heightfield(hf, 10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.2)
    
    // Add a span using the add_span function
    success := add_span(hf, 5, 5, 0, 11, 63, 1)
    testing.expect(t, success, "Failed to add first span")
    
    // Check the span was added correctly
    span := hf.spans[5 + 5*10]
    testing.expect(t, span != nil, "Span was not created")
    if span != nil {
        log.infof("Added span: smin=%d, smax=%d, area=%d", span.smin, span.smax, span.area)
        testing.expectf(t, span.smin == 0, "Expected smin=0, got %d", span.smin)
        testing.expectf(t, span.smax == 11, "Expected smax=11, got %d", span.smax)
        testing.expectf(t, span.area == 63, "Expected area=63, got %d", span.area)
    }
    
    // Try adding another span at same location that overlaps
    success2 := add_span(hf, 5, 5, 10, 11, 63, 1)
    testing.expect(t, success2, "Failed to add overlapping span")
    
    // Check the merged result
    span2 := hf.spans[5 + 5*10]
    testing.expect(t, span2 != nil, "Span was deleted")
    if span2 != nil {
        log.infof("After merge: smin=%d, smax=%d, area=%d", span2.smin, span2.smax, span2.area)
        testing.expectf(t, span2.smin == 0, "Expected merged smin=0, got %d", span2.smin)
        testing.expectf(t, span2.smax == 11, "Expected merged smax=11, got %d", span2.smax)
        testing.expectf(t, span2.area == 63, "Expected area=63, got %d", span2.area)
        testing.expect(t, span2.next == nil, "Expected single span after merge")
    }
}