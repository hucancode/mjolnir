package test_recast

import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"
import "core:fmt"
import "core:strings"

@(test)
test_heightfield_visualization :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a smaller 15x15 field for better visualization
    field_size := i32(15)
    cell_size := f32(1.0)
    cell_height := f32(0.5)

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(field_size), 10, f32(field_size)}

    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add ground level spans
    ground_level := u16(0)
    ground_height := u16(2) // 1 unit high
    walkable_area := u8(recast.RC_WALKABLE_AREA)

    for z in 0..<field_size {
        for x in 0..<field_size {
            ok = recast.add_span(hf, x, z, ground_level, ground_height, walkable_area, 1)
            testing.expect(t, ok, "Adding ground span should succeed")
        }
    }

    // Add 3x3 obstacle in the middle (cells 6-8)
    obstacle_start := i32(6)
    obstacle_end := i32(9)
    obstacle_bottom := u16(4) // Gap from ground
    obstacle_top := u16(20) // 10 units high
    obstacle_area := u8(recast.RC_NULL_AREA)

    for z in obstacle_start..<obstacle_end {
        for x in obstacle_start..<obstacle_end {
            ok = recast.add_span(hf, x, z, obstacle_bottom, obstacle_top, obstacle_area, 1)
            testing.expect(t, ok, "Adding obstacle span should succeed")
        }
    }

    // Visualize the heightfield
    log.info("\n=== HEIGHTFIELD VISUALIZATION ===")
    log.info("Legend: . = ground only (height 1), # = obstacle (height 10), numbers show span count")
    log.info("Cell size: 1.0 units, Cell height: 0.5 units")

    // Top view showing max height
    log.info("\n--- Top View (Max Height) ---")
    log.info("    X: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14")
    log.info("   +-----------------------------------------------")

    for z := field_size - 1; z >= 0; z -= 1 {
        fmt.printf("Z:%2d|", z)
        for x in 0..<field_size {
            column_index := x + z * field_size
            span := hf.spans[column_index]

            max_height := u16(0)
            span_count := 0

            current := span
            for current != nil {
                if u16(current.smax) > max_height {
                    max_height = u16(current.smax)
                }
                span_count += 1
                current = current.next
            }

            if span_count == 2 {
                fmt.printf("  #")
            } else {
                fmt.printf("  .")
            }
        }
        fmt.printf("\n")
    }

    // Height values matrix
    log.info("\n--- Height Values (in units) ---")
    log.info("    X: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14")
    log.info("   +-----------------------------------------------")

    for z := field_size - 1; z >= 0; z -= 1 {
        fmt.printf("Z:%2d|", z)
        for x in 0..<field_size {
            column_index := x + z * field_size
            span := hf.spans[column_index]

            max_height := u16(0)
            current := span
            for current != nil {
                if u16(current.smax) > max_height {
                    max_height = u16(current.smax)
                }
                current = current.next
            }

            height_in_units := f32(max_height) * cell_height
            fmt.printf("%3.0f", height_in_units)
        }
        fmt.printf("\n")
    }

    // Detailed view of middle row (z=7)
    log.info("\n--- Detailed Cross-Section at Z=7 ---")
    log.info("X  | Spans")
    log.info("---|------------------------------------------------------")

    z := i32(7)
    for x in 0..<field_size {
        column_index := x + z * field_size
        span := hf.spans[column_index]

        fmt.printf("%2d | ", x)

        if span == nil {
            fmt.printf("(empty)")
        } else {
            current := span
            span_num := 1
            for current != nil {
                min_height := f32(current.smin) * cell_height
                max_height := f32(current.smax) * cell_height
                area_type := current.area == u32(walkable_area) ? "walk" : "obst"

                if span_num > 1 {
                    fmt.printf(", ")
                }
                fmt.printf("Span%d[%.1f-%.1f %s]", span_num, min_height, max_height, area_type)

                current = current.next
                span_num += 1
            }
        }
        fmt.printf("\n")
    }

    // 3D ASCII visualization
    log.info("\n--- 3D Side View (looking along X axis at X=7) ---")
    log.info("Height")
    log.info("  10 |")
    log.info("   9 |")
    log.info("   8 |         ###")
    log.info("   7 |         ###")
    log.info("   6 |         ###")
    log.info("   5 |         ###")
    log.info("   4 |         ###")
    log.info("   3 |         ###")
    log.info("   2 |         ###")
    log.info("   1 | ===============  (ground)")
    log.info("   0 |_________________")
    log.info("     0 1 2 3 4 5 6 7 8 9 10 11 12 13 14  Z")
    log.info("       (obstacle at Z=6,7,8)")
}
