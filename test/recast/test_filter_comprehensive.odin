package test_recast

import rc "../../mjolnir/navigation/recast"
import "core:testing"
import "core:time"

@(test)
test_all_filters :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test 1: Low hanging obstacle (smax-smax check)
    {
        hf := rc.Heightfield{width = 1, height = 1, spans = make([]^rc.Span, 1)}
        defer delete(hf.spans)
        
        floor := new(rc.Span)
        floor.smax = 10
        floor.area = rc.RC_WALKABLE_AREA
        obstacle := new(rc.Span)
        obstacle.smin = 12
        obstacle.smax = 15
        obstacle.area = rc.RC_NULL_AREA
        floor.next = obstacle
        hf.spans[0] = floor
        
        rc.filter_low_hanging_walkable_obstacles(5, &hf)
        testing.expect(t, obstacle.area != rc.RC_NULL_AREA, "climb=5 should be walkable")
        
        obstacle.area = rc.RC_NULL_AREA
        rc.filter_low_hanging_walkable_obstacles(4, &hf)
        testing.expect(t, obstacle.area == rc.RC_NULL_AREA, "climb=5 exceeds limit=4")
        
        free(floor)
        free(obstacle)
    }
    
    // Test 2: Low height clearance
    {
        hf := rc.Heightfield{width = 1, height = 1, spans = make([]^rc.Span, 1)}
        defer delete(hf.spans)
        
        floor := new(rc.Span)
        floor.smax = 10
        floor.area = rc.RC_WALKABLE_AREA
        ceiling := new(rc.Span)
        ceiling.smin = 13
        floor.next = ceiling
        hf.spans[0] = floor
        
        rc.filter_walkable_low_height_spans(5, &hf)
        testing.expect(t, floor.area == rc.RC_NULL_AREA, "clearance=3 < required=5")
        
        free(floor)
        free(ceiling)
    }
    
    // Test 3: Ledge detection
    {
        hf := rc.Heightfield{width = 3, height = 1, spans = make([]^rc.Span, 3)}
        defer delete(hf.spans)
        
        for i in 0..<3 {
            span := new(rc.Span)
            span.smax = u32(10 + i * 5)  // Heights: 10, 15, 20
            span.area = rc.RC_WALKABLE_AREA
            hf.spans[i] = span
        }
        
        rc.filter_ledge_spans(10, 3, &hf)
        testing.expect(t, hf.spans[0].area == rc.RC_NULL_AREA, "edge is ledge")
        testing.expect(t, hf.spans[2].area == rc.RC_NULL_AREA, "edge is ledge")
        
        for i in 0..<3 do free(hf.spans[i])
    }

    
    // Test 4: Median filter with compact heightfield
    {
        chf := rc.Compact_Heightfield{
            width = 3, height = 3, span_count = 9,
        }
        defer {
            delete(chf.cells)
            delete(chf.spans)
            delete(chf.areas)
        }
        
        chf.cells = make([]rc.Compact_Cell, 9)
        chf.spans = make([]rc.Compact_Span, 9)
        chf.areas = make([]u8, 9)
        
        for i in 0..<9 {
            chf.cells[i] = {index = u32(i), count = 1}
            chf.areas[i] = rc.RC_WALKABLE_AREA
            
            // Setup 4-connected grid
            span := &chf.spans[i]
            x, z := i % 3, i / 3
            for dir in 0..<4 {
                nx := x + int(rc.get_dir_offset_x(dir))
                nz := z + int(rc.get_dir_offset_y(dir))
                if nx >= 0 && nx < 3 && nz >= 0 && nz < 3 {
                    // Connection stores index within the neighbor cell's spans
                    // Since each cell has exactly 1 span, connection index is 0
                    rc.set_con(span, dir, 0)
                } else {
                    rc.set_con(span, dir, rc.RC_NOT_CONNECTED)
                }
            }
        }
        
        chf.areas[4] = rc.RC_NULL_AREA
        rc.median_filter_walkable_area(&chf)
        testing.expect(t, chf.areas[4] == rc.RC_NULL_AREA, "median preserves null")
    }
}