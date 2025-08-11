package test_recast

import rc "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:slice"
import "core:time"

@(test)
test_low_hanging_obstacle_filter_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test 1: Height-based climbing (correct approach - agent climbs from smax to smax)
    {
        // Create heightfield with specific spans
        hf := rc.Heightfield{
            width = 1,
            height = 1,
            bmin = {0, 0, 0},
            bmax = {1, 20, 1},
            cs = 1.0,
            ch = 1.0,
        }
        hf.spans = make([]^rc.Span, 1)
        
        // Create walkable floor span [0, 10] - agent stands at height 10
        span1 := new(rc.Span)
        span1.smin = 0
        span1.smax = 10
        span1.area = rc.RC_WALKABLE_AREA
        
        // Create non-walkable obstacle [12, 15] - agent needs to reach height 15
        span2 := new(rc.Span)
        span2.smin = 12
        span2.smax = 15
        span2.area = rc.RC_NULL_AREA
        span1.next = span2
        
        hf.spans[0] = span1
        
        // Apply filter with walkableClimb = 5
        rc.filter_low_hanging_walkable_obstacles(5, &hf)
        
        // Climb height is 5 (15-10), should be walkable since 5 <= 5
        testing.expect(t, span2.area != rc.RC_NULL_AREA, 
                      "Span with climb height=5 should be walkable with walkableClimb=5")
        
        // Reset and test with walkableClimb = 4
        span2.area = rc.RC_NULL_AREA
        rc.filter_low_hanging_walkable_obstacles(4, &hf)
        
        // Climb height is 5, should NOT be walkable since 5 > 4
        testing.expect(t, span2.area == rc.RC_NULL_AREA,
                      "Span with climb height=5 should NOT be walkable with walkableClimb=4")
        
        free(span1)
        free(span2)
        delete(hf.spans)
    }
    
    // Test 2: Thick platform test
    {
        hf := rc.Heightfield{
            width = 1,
            height = 1,
            bmin = {0, 0, 0},
            bmax = {1, 25, 1},
            cs = 1.0,
            ch = 1.0,
        }
        hf.spans = make([]^rc.Span, 1)
        
        // Create walkable span [0, 10] - agent at height 10
        span1 := new(rc.Span)
        span1.smin = 0
        span1.smax = 10
        span1.area = rc.RC_WALKABLE_AREA
        
        // Create thick non-walkable platform [11, 20] - agent needs to reach height 20
        span2 := new(rc.Span)
        span2.smin = 11
        span2.smax = 20
        span2.area = rc.RC_NULL_AREA
        span1.next = span2
        
        hf.spans[0] = span1
        
        // Apply filter with walkableClimb = 5
        rc.filter_low_hanging_walkable_obstacles(5, &hf)
        
        // Climb height is 10 (20-10), should NOT be walkable since 10 > 5
        testing.expect(t, span2.area == rc.RC_NULL_AREA,
                      "Thick platform requiring 10 unit climb should not be walkable with walkableClimb=5")
        
        free(span1)
        free(span2)
        delete(hf.spans)
    }
    
    // Test 3: Adjacent spans test
    {
        hf := rc.Heightfield{
            width = 1,
            height = 1,
            bmin = {0, 0, 0},
            bmax = {1, 20, 1},
            cs = 1.0,
            ch = 1.0,
        }
        hf.spans = make([]^rc.Span, 1)
        
        // Create walkable span [0, 10]
        span1 := new(rc.Span)
        span1.smin = 0
        span1.smax = 10
        span1.area = rc.RC_WALKABLE_AREA
        
        // Create adjacent non-walkable span [10, 15]
        span2 := new(rc.Span)
        span2.smin = 10
        span2.smax = 15
        span2.area = rc.RC_NULL_AREA
        span1.next = span2
        
        hf.spans[0] = span1
        
        // Apply filter with walkableClimb = 5
        rc.filter_low_hanging_walkable_obstacles(5, &hf)
        
        // Climb height is 5 (15-10), should be walkable since 5 <= 5
        testing.expect(t, span2.area != rc.RC_NULL_AREA,
                      "Adjacent span with climb=5 should be walkable with walkableClimb=5")
        
        // Reset and test with smaller walkableClimb
        span2.area = rc.RC_NULL_AREA
        rc.filter_low_hanging_walkable_obstacles(4, &hf)
        
        // Climb height is 5, should NOT be walkable since 5 > 4
        testing.expect(t, span2.area == rc.RC_NULL_AREA,
                      "Adjacent span with climb=5 should NOT be walkable with walkableClimb=4")
        
        free(span1)
        free(span2)
        delete(hf.spans)
    }
    
    // Test 4: Multiple consecutive non-walkable spans
    {
        hf := rc.Heightfield{
            width = 1,
            height = 1,
            bmin = {0, 0, 0},
            bmax = {1, 30, 1},
            cs = 1.0,
            ch = 1.0,
        }
        hf.spans = make([]^rc.Span, 1)
        
        // Create walkable span
        span1 := new(rc.Span)
        span1.smin = 0
        span1.smax = 10
        span1.area = rc.RC_WALKABLE_AREA
        
        // Create first non-walkable span with small gap
        span2 := new(rc.Span)
        span2.smin = 12
        span2.smax = 15
        span2.area = rc.RC_NULL_AREA
        span1.next = span2
        
        // Create second non-walkable span with small gap from span2
        span3 := new(rc.Span)
        span3.smin = 17
        span3.smax = 20
        span3.area = rc.RC_NULL_AREA
        span2.next = span3
        
        hf.spans[0] = span1
        
        // Apply filter with walkableClimb = 5
        rc.filter_low_hanging_walkable_obstacles(5, &hf)
        
        // Only span2 should become walkable (gap=2 from span1)
        // span3 should remain non-walkable (it's not directly above a walkable span)
        testing.expect(t, span2.area != rc.RC_NULL_AREA,
                      "First non-walkable span should become walkable")
        testing.expect(t, span3.area == rc.RC_NULL_AREA,
                      "Second non-walkable span should remain non-walkable")
        
        free(span1)
        free(span2)
        free(span3)
        delete(hf.spans)
    }
    
    log.info("Low hanging obstacle filter edge cases passed")
}

@(test)
test_ledge_filter_steep_slope :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test steep slope detection
    {
        hf := rc.Heightfield{
            width = 3,
            height = 3,
            bmin = {0, 0, 0},
            bmax = {3, 20, 3},
            cs = 1.0,
            ch = 1.0,
        }
        hf.spans = make([]^rc.Span, 9)
        
        // Create a steep slope scenario
        // Center span at height 10
        center_span := new(rc.Span)
        center_span.smin = 0
        center_span.smax = 10
        center_span.area = rc.RC_WALKABLE_AREA
        hf.spans[4] = center_span // Center of 3x3 grid
        
        // Create neighbors at varying heights
        // Low neighbor at height 7 (traversable)
        low_span := new(rc.Span)
        low_span.smin = 0
        low_span.smax = 7
        low_span.area = rc.RC_WALKABLE_AREA
        hf.spans[3] = low_span // Left neighbor
        
        // High neighbor at height 11 (traversable)
        high_span := new(rc.Span)
        high_span.smin = 0
        high_span.smax = 11
        high_span.area = rc.RC_WALKABLE_AREA
        hf.spans[5] = high_span // Right neighbor
        
        walkable_height := 10
        walkable_climb := 3
        
        // Apply ledge filter
        rc.filter_ledge_spans(walkable_height, walkable_climb, &hf)
        
        // The center span should be marked as unwalkable because
        // the difference between highest and lowest traversable neighbors (11-7=4) > walkableClimb (3)
        testing.expect(t, center_span.area == rc.RC_NULL_AREA,
                      "Center span should be marked as ledge due to steep slope")
        
        free(center_span)
        free(low_span)
        free(high_span)
        delete(hf.spans)
    }
    
    log.info("Ledge filter steep slope test passed")
}

@(test)
test_walkable_low_height_filter :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test filtering spans without enough clearance
    {
        hf := rc.Heightfield{
            width = 1,
            height = 1,
            bmin = {0, 0, 0},
            bmax = {1, 20, 1},
            cs = 1.0,
            ch = 1.0,
        }
        hf.spans = make([]^rc.Span, 1)
        
        // Create walkable span with limited clearance
        span1 := new(rc.Span)
        span1.smin = 0
        span1.smax = 10
        span1.area = rc.RC_WALKABLE_AREA
        
        // Create ceiling span
        span2 := new(rc.Span)
        span2.smin = 13  // Only 3 units of clearance
        span2.smax = 20
        span2.area = rc.RC_NULL_AREA
        span1.next = span2
        
        hf.spans[0] = span1
        
        // Apply filter with walkableHeight = 5
        rc.filter_walkable_low_height_spans(5, &hf)
        
        // span1 should be marked unwalkable (clearance=3 < walkableHeight=5)
        testing.expect(t, span1.area == rc.RC_NULL_AREA,
                      "Span with insufficient clearance should be unwalkable")
        
        // Reset and test with adequate clearance
        span1.area = rc.RC_WALKABLE_AREA
        span2.smin = 16  // 6 units of clearance
        
        rc.filter_walkable_low_height_spans(5, &hf)
        
        // span1 should remain walkable (clearance=6 >= walkableHeight=5)
        testing.expect(t, span1.area != rc.RC_NULL_AREA,
                      "Span with sufficient clearance should remain walkable")
        
        free(span1)
        free(span2)
        delete(hf.spans)
    }
    
    log.info("Walkable low height filter test passed")
}