package test_recast

import "core:testing"
import "core:math"
import "core:slice"
import "core:time"
import "../../mjolnir/navigation/recast"

@(test)
test_offset_poly :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test 1: Simple square polygon (clockwise winding for proper inset)
    {
        // Define a square centered at origin with clockwise winding
        verts := [][3]f32{
            {-1, 0, -1},  // vertex 0
            {-1, 0,  1},  // vertex 1
            { 1, 0,  1},  // vertex 2
            { 1, 0, -1},  // vertex 3
        }

        // Test inset by 0.5 (positive offset creates inset for clockwise polygons)
        out_verts, ok := recast.offset_poly(verts, 0.5)
        defer delete(out_verts)

        testing.expect(t, ok, "Expected offset_poly to succeed")
        testing.expect(t, len(out_verts) == 4, "Expected 4 vertices for simple square inset")

        // Verify the inset square has correct dimensions (should be 1x1 square instead of 2x2)
        if ok && len(out_verts) == 4 {
            // For a positive offset on clockwise polygon, vertices should be closer to center
            for i in 0..<4 {
                x := out_verts[i].x
                z := out_verts[i].z
                // Original square is from -1 to 1, inset by 0.5 should give -0.5 to 0.5
                testing.expect(t, math.abs(x) <= 0.5+0.01, "X coordinate should be within inset bounds")
                testing.expect(t, math.abs(z) <= 0.5+0.01, "Z coordinate should be within inset bounds")
            }
        }
    }

    // Test 2: Triangle with acute angle (should create bevel)
    {
        // Acute triangle that should trigger beveling
        verts := [][3]f32{
            {0, 0, 0},      // vertex 0 (sharp point)
            {4, 0, -1},     // vertex 1
            {4, 0, 1},      // vertex 2
        }

        // Test outset (positive offset)
        out_verts, ok := recast.offset_poly(verts, 0.5)
        defer delete(out_verts)

        testing.expect(t, ok, "Expected offset_poly to succeed")
        // Should produce more than 3 vertices due to beveling at acute angle
        testing.expect(t, len(out_verts) >= 3, "Should produce at least 3 vertices")
        testing.expect(t, len(out_verts) <= 6, "Should produce at most 6 vertices (with bevels)")
    }

    // Test 3: Regular hexagon (no beveling expected)
    {
        // Regular hexagon
        verts: [6][3]f32
        for i in 0..<6 {
            angle := f32(i) * math.TAU / 6
            verts[i].x = math.cos(angle) * 2
            verts[i].y = 0
            verts[i].z = math.sin(angle) * 2
        }

        out_verts, ok := recast.offset_poly(verts[:], 0.5)
        defer delete(out_verts)

        testing.expect(t, ok, "Expected offset_poly to succeed")
        testing.expect(t, len(out_verts) == 6, "Regular hexagon should maintain 6 vertices")
    }

    // Test 4: Edge case - offset too large
    {
        // Small triangle
        verts := [][3]f32{
            {0, 0, 0},
            {0.5, 0, 0},
            {0.25, 0, 0.5},
        }

        // Try to offset by more than the polygon can handle
        out_verts, ok := recast.offset_poly(verts, 5.0)
        defer delete(out_verts)

        // Function should still work, producing some result
        testing.expect(t, ok, "Should handle large offsets gracefully")
    }

    // Test 5: Zero vertices
    {
        verts: [][3]f32

        out_verts, ok := recast.offset_poly(verts, 0.1)
        defer delete(out_verts)

        testing.expect(t, !ok, "Should return false for zero vertices")
        testing.expect(t, out_verts == nil, "Should return nil for zero vertices")
    }
}

@(test)
test_safe_normalize :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test 1: Normal vector
    {
        v := [3]f32{3, 4, 0}
        recast.safe_normalize(&v)

        expected_len := math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
        testing.expect(t, math.abs(expected_len - 1.0) < 0.001, "Normalized vector should have length 1")
        testing.expect(t, math.abs(v.x - 0.6) < 0.001, "X component should be 0.6")
        testing.expect(t, math.abs(v.y - 0.8) < 0.001, "Y component should be 0.8")
    }

    // Test 2: Zero vector (should remain unchanged)
    {
        v := [3]f32{0, 0, 0}
        recast.safe_normalize(&v)

        testing.expect(t, v.x == 0.0, "Zero vector X should remain 0")
        testing.expect(t, v.y == 0.0, "Zero vector Y should remain 0")
        testing.expect(t, v.z == 0.0, "Zero vector Z should remain 0")
    }

    // Test 3: Very small vector (below epsilon)
    {
        v := [3]f32{1e-7, 1e-7, 1e-7}
        v_copy := v
        recast.safe_normalize(&v)

        // Should remain unchanged if below epsilon threshold
        testing.expect(t, v.x == v_copy.x && v.y == v_copy.y && v.z == v_copy.z,
                      "Very small vector should remain unchanged")
    }
}
