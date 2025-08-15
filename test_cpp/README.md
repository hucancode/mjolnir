# C++ Recast/Detour/Crowd Test Suite

This directory contains comprehensive C++ tests that mirror the Odin implementation tests for the Recast/Detour/Crowd navigation library. These tests serve as a reference implementation to verify that the Odin port correctly matches the original C++ library behavior.

## Purpose

These tests help verify that:
1. The Odin port of Recast/Detour/Crowd produces the same results as the original C++ library
2. All major features and edge cases are properly handled
3. Performance characteristics are comparable

## Test Coverage

### Recast Tests (✅ Completed)

#### `test_recast_heightfield.cpp`
- Heightfield allocation and initialization
- Heightfield creation with various parameters
- Compact heightfield building
- Triangle rasterization
- Distance field generation
- Region building (watershed, monotone, layers)
- Contour generation
- Polygon mesh building
- Complete pipeline integration

#### `test_filter.cpp`
- Low hanging obstacle filtering
- Ledge span filtering
- Walkable low height span filtering
- Combined filter operations
- Walkable area erosion

#### `test_regions.cpp`
- Compact heightfield building
- Walkable area erosion
- Distance field building
- Watershed region generation
- Monotone region partitioning
- Layer-based region building
- Region merging

#### `test_contour_simplification.cpp`
- Distance calculation algorithms
- Contour simplification with varying error tolerances
- Contours with holes
- Edge case handling (single cells, diagonal connections)

#### `test_mesh_detail.cpp`
- Basic detail mesh generation
- Empty input handling
- Varying sample distances
- Complex terrain handling
- Edge connectivity

#### `test_area_marking.cpp`
- Triangle walkability based on slope
- Convex volume area marking
- Cylindrical area marking
- Box area marking
- Area filtering (median filter)

### Detour Tests (⚠️ Has memory issues)

#### `test_detour_navmesh.cpp`
- NavMesh creation
- NavMesh query initialization
- Finding nearest polygon
- Pathfinding
- Raycasting
- Distance to wall queries
- Local neighborhood queries

### Crowd Tests (⚠️ Not fully tested)

#### `test_crowd_simulation.cpp`
- Crowd creation and initialization
- Agent addition
- Agent movement
- Obstacle avoidance
- Velocity obstacles
- Performance with many agents

## Building the Tests

```bash
# Build all tests
make all

# Build specific test
make test_recast_heightfield
make test_filter
make test_regions
# ... etc

# Clean build artifacts
make clean
```

## Running the Tests

### Run All Tests
```bash
./run_all_tests.sh
```

### Run Individual Tests
```bash
./test_recast_heightfield
./test_filter
./test_regions
./test_contour_simplification
./test_mesh_detail
./test_area_marking
```

## Test Results Summary

| Test Suite | Status | Tests Passing | Notes |
|------------|--------|---------------|-------|
| Recast Heightfield | ✅ Pass | 12/12 | All core heightfield operations verified |
| Recast Filter | ✅ Pass | 6/6 | All filtering operations working |
| Recast Regions | ✅ Pass | 7/7 | All region building algorithms verified |
| Contour Simplification | ✅ Pass | 4/4 | Simplification and edge cases handled |
| Mesh Detail | ⚠️ Partial | 2/5 | Segfault in complex terrain test |
| Area Marking | ⚠️ Partial | 4/5 | Slope calculation needs adjustment |
| Detour NavMesh | ❌ Fail | 0/7 | Memory management issue |
| Crowd Simulation | ❌ Not Run | 0/6 | Compilation issues |

## Known Issues

1. **Memory Management**: Some tests have double-free errors, particularly in Detour tests
2. **API Differences**: Some marking functions work on CompactHeightfield vs regular Heightfield
3. **Slope Calculations**: Triangle slope tests need adjustment for proper angle calculations

## Comparing with Odin Implementation

To verify the Odin port:

1. Run the C++ tests and capture output
2. Run equivalent Odin tests
3. Compare numerical outputs (vertices, triangles, regions, etc.)
4. Verify that the counts and structures match within acceptable tolerances

## Future Improvements

- Fix memory management issues in Detour tests
- Complete Crowd simulation tests
- Add performance benchmarks
- Create automated comparison tools
- Add more edge case tests
- Implement visual output comparison

## Dependencies

- C++11 or later
- Recast/Detour/Crowd source (included in `docs/recastnavigation/`)
- Make build system
- Standard C++ library

## Contributing

When adding new tests:
1. Create equivalent test in both C++ and Odin
2. Ensure consistent test data and parameters
3. Document expected outputs
4. Update this README with test coverage