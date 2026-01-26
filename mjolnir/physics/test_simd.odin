package physics

import "../geometry"
import "core:math"
import "core:math/linalg"
import "core:log"
import "core:slice"
import "core:time"
import "core:testing"

// Epsilon for floating point comparisons
EPSILON :: 1e-5

// Helper to compare f32 with epsilon tolerance
approx_equal_f32 :: proc(a, b: f32, epsilon := EPSILON) -> bool {
  return math.abs(a - b) < f32(epsilon)
}

// Helper to compare [3]f32 with epsilon tolerance
approx_equal_vec3 :: proc(a, b: [3]f32, epsilon := EPSILON) -> bool {
  return(
    approx_equal_f32(a.x, b.x, epsilon) &&
    approx_equal_f32(a.y, b.y, epsilon) &&
    approx_equal_f32(a.z, b.z, epsilon) \
  )
}

// Helper to compare Aabb with epsilon tolerance
approx_equal_aabb :: proc(a, b: geometry.Aabb, epsilon := EPSILON) -> bool {
  return(
    approx_equal_vec3(a.min, b.min, epsilon) &&
    approx_equal_vec3(a.max, b.max, epsilon) \
  )
}

@(test)
test_obb_to_aabb_batch4_identity :: proc(t: ^testing.T) {
  // Test with identity rotations (should produce simple AABBs)
  obbs: [4]geometry.Obb

  // OBB 1: centered at origin
  obbs[0] = geometry.Obb {
    center       = {0, 0, 0},
    half_extents = {1, 2, 3},
    rotation     = linalg.QUATERNIONF32_IDENTITY,
  }

  // OBB 2: offset from origin
  obbs[1] = geometry.Obb {
    center       = {5, 10, 15},
    half_extents = {0.5, 1.5, 2.5},
    rotation     = linalg.QUATERNIONF32_IDENTITY,
  }

  // OBB 3: different extents
  obbs[2] = geometry.Obb {
    center       = {-10, 5, 0},
    half_extents = {2, 2, 2},
    rotation     = linalg.QUATERNIONF32_IDENTITY,
  }

  // OBB 4: small box
  obbs[3] = geometry.Obb {
    center       = {0, 100, -50},
    half_extents = {0.1, 0.2, 0.3},
    rotation     = linalg.QUATERNIONF32_IDENTITY,
  }

  // Compute reference AABBs with scalar path
  expected: [4]geometry.Aabb
  for i in 0 ..< 4 {
    expected[i] = geometry.obb_to_aabb(obbs[i])
  }

  // Compute AABBs with SIMD batch path
  result: [4]geometry.Aabb
  obb_to_aabb_batch4(obbs, &result)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      approx_equal_aabb(result[i], expected[i]),
      "OBB %d: SIMD result doesn't match scalar. Got min=%v max=%v, expected min=%v max=%v",
      i,
      result[i].min,
      result[i].max,
      expected[i].min,
      expected[i].max,
    )
  }
}

@(test)
test_obb_to_aabb_batch4_rotated :: proc(t: ^testing.T) {
  // Test with rotated OBBs
  obbs: [4]geometry.Obb

  // OBB 1: rotated 45 degrees around Y axis
  obbs[0] = geometry.Obb {
    center       = {0, 0, 0},
    half_extents = {1, 1, 1},
    rotation     = linalg.quaternion_angle_axis(
      math.PI / 4.0,
      linalg.VECTOR3F32_Y_AXIS,
    ),
  }

  // OBB 2: rotated 90 degrees around X axis
  obbs[1] = geometry.Obb {
    center       = {5, 5, 5},
    half_extents = {1, 2, 3},
    rotation     = linalg.quaternion_angle_axis(
      math.PI / 2.0,
      linalg.VECTOR3F32_X_AXIS,
    ),
  }

  // OBB 3: rotated around Z axis
  obbs[2] = geometry.Obb {
    center       = {-5, 0, 10},
    half_extents = {2, 0.5, 1},
    rotation     = linalg.quaternion_angle_axis(
      math.PI / 3.0,
      linalg.VECTOR3F32_Z_AXIS,
    ),
  }

  // OBB 4: complex rotation
  obbs[3] = geometry.Obb {
    center       = {10, -10, 5},
    half_extents = {1, 1, 2},
    rotation     = linalg.quaternion_angle_axis_f32(
      f32(math.PI / 6.0),
      [3]f32{1, 1, 1},
    ),
  }

  // Compute reference AABBs with scalar path
  expected: [4]geometry.Aabb
  for i in 0 ..< 4 {
    expected[i] = geometry.obb_to_aabb(obbs[i])
  }

  // Compute AABBs with SIMD batch path
  result: [4]geometry.Aabb
  obb_to_aabb_batch4(obbs, &result)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      approx_equal_aabb(result[i], expected[i]),
      "Rotated OBB %d: SIMD result doesn't match scalar. Got min=%v max=%v, expected min=%v max=%v",
      i,
      result[i].min,
      result[i].max,
      expected[i].min,
      expected[i].max,
    )
  }
}

@(test)
test_vector_cross3_batch4 :: proc(t: ^testing.T) {
  // Test batch cross product
  a: [4][3]f32
  b: [4][3]f32

  // Case 1: X cross Y = Z
  a[0] = {1, 0, 0}
  b[0] = {0, 1, 0}

  // Case 2: Y cross Z = X
  a[1] = {0, 1, 0}
  b[1] = {0, 0, 1}

  // Case 3: Z cross X = Y
  a[2] = {0, 0, 1}
  b[2] = {1, 0, 0}

  // Case 4: Arbitrary vectors
  a[3] = {1, 2, 3}
  b[3] = {4, 5, 6}

  // Compute reference with scalar path
  expected: [4][3]f32
  for i in 0 ..< 4 {
    expected[i] = linalg.cross(a[i], b[i])
  }
  result := vector_cross3_batch4(a, b)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      approx_equal_vec3(result[i], expected[i]),
      "Cross product %d: SIMD result doesn't match scalar. Got %v, expected %v",
      i,
      result[i],
      expected[i],
    )
  }

  // Verify specific expected results
  testing.expectf(
    t,
    approx_equal_vec3(result[0], {0, 0, 1}),
    "X cross Y should be Z, got %v",
    result[0],
  )
  testing.expectf(
    t,
    approx_equal_vec3(result[1], {1, 0, 0}),
    "Y cross Z should be X, got %v",
    result[1],
  )
  testing.expectf(
    t,
    approx_equal_vec3(result[2], {0, 1, 0}),
    "Z cross X should be Y, got %v",
    result[2],
  )
}

@(test)
test_quaternion_mul_vector3_batch4 :: proc(t: ^testing.T) {
  // Test batch quaternion-vector multiplication
  q: [4]quaternion128
  v: [4][3]f32

  // Case 1: Identity quaternion (no rotation)
  q[0] = linalg.QUATERNIONF32_IDENTITY
  v[0] = {1, 2, 3}

  // Case 2: 90 degree rotation around Y axis
  q[1] = linalg.quaternion_angle_axis(math.PI / 2.0, linalg.VECTOR3F32_Y_AXIS)
  v[1] = {1, 0, 0}

  // Case 3: 180 degree rotation around X axis
  q[2] = linalg.quaternion_angle_axis(math.PI, linalg.VECTOR3F32_X_AXIS)
  v[2] = {0, 1, 0}

  // Case 4: Arbitrary rotation
  q[3] = linalg.quaternion_angle_axis_f32(f32(math.PI / 4.0), [3]f32{1, 1, 1})
  v[3] = {1, 1, 1}

  // Compute reference with scalar path
  expected: [4][3]f32
  for i in 0 ..< 4 {
    expected[i] = linalg.mul(q[i], v[i])
  }
  result := quaternion_mul_vector3_batch4(q, v)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      approx_equal_vec3(result[i], expected[i]),
      "Quaternion mul %d: SIMD result doesn't match scalar. Got %v, expected %v",
      i,
      result[i],
      expected[i],
    )
  }

  // Verify specific expected results
  testing.expectf(
    t,
    approx_equal_vec3(result[0], v[0]),
    "Identity quaternion should not change vector, got %v",
    result[0],
  )
  testing.expectf(
    t,
    approx_equal_vec3(result[1], {0, 0, -1}),
    "90deg Y rotation of (1,0,0) should be (0,0,-1), got %v",
    result[1],
  )
  testing.expectf(
    t,
    approx_equal_vec3(result[2], {0, -1, 0}),
    "180deg X rotation of (0,1,0) should be (0,-1,0), got %v",
    result[2],
  )
}

@(test)
test_vector_dot3_batch4 :: proc(t: ^testing.T) {
  // Test batch dot product
  a: [4][3]f32
  b: [4][3]f32

  // Case 1: Orthogonal vectors (dot = 0)
  a[0] = {1, 0, 0}
  b[0] = {0, 1, 0}

  // Case 2: Parallel vectors (dot = length product)
  a[1] = {2, 0, 0}
  b[1] = {3, 0, 0}

  // Case 3: Opposite vectors (dot = -length product)
  a[2] = {1, 0, 0}
  b[2] = {-1, 0, 0}

  // Case 4: Arbitrary vectors
  a[3] = {1, 2, 3}
  b[3] = {4, 5, 6}

  // Compute reference with scalar path
  expected: [4]f32
  for i in 0 ..< 4 {
    expected[i] = linalg.dot(a[i], b[i])
  }
  result := vector_dot3_batch4(a, b)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      approx_equal_f32(result[i], expected[i]),
      "Dot product %d: SIMD result doesn't match scalar. Got %v, expected %v",
      i,
      result[i],
      expected[i],
    )
  }

  // Verify specific expected results
  testing.expectf(
    t,
    approx_equal_f32(result[0], 0),
    "Orthogonal vectors should have dot=0, got %v",
    result[0],
  )
  testing.expectf(
    t,
    approx_equal_f32(result[1], 6),
    "Parallel vectors (2,0,0)·(3,0,0) should be 6, got %v",
    result[1],
  )
  testing.expectf(
    t,
    approx_equal_f32(result[2], -1),
    "Opposite vectors should have negative dot, got %v",
    result[2],
  )
  testing.expectf(
    t,
    approx_equal_f32(result[3], 32),
    "(1,2,3)·(4,5,6) should be 32, got %v",
    result[3],
  )
}

@(test)
test_vector_length3_batch4 :: proc(t: ^testing.T) {
  // Test batch vector length
  v: [4][3]f32

  // Case 1: Unit vector
  v[0] = {1, 0, 0}

  // Case 2: (3,4,0) - length = 5
  v[1] = {3, 4, 0}

  // Case 3: (1,1,1) - length = sqrt(3)
  v[2] = {1, 1, 1}

  // Case 4: Zero vector
  v[3] = {0, 0, 0}

  // Compute reference with scalar path
  expected: [4]f32
  for i in 0 ..< 4 {
    expected[i] = linalg.length(v[i])
  }
  result := vector_length3_batch4(v)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      approx_equal_f32(result[i], expected[i]),
      "Vector length %d: SIMD result doesn't match scalar. Got %v, expected %v",
      i,
      result[i],
      expected[i],
    )
  }

  // Verify specific expected results
  testing.expectf(
    t,
    approx_equal_f32(result[0], 1),
    "Unit vector should have length 1, got %v",
    result[0],
  )
  testing.expectf(
    t,
    approx_equal_f32(result[1], 5),
    "(3,4,0) should have length 5, got %v",
    result[1],
  )
  testing.expectf(
    t,
    approx_equal_f32(result[2], math.sqrt(f32(3))),
    "(1,1,1) should have length sqrt(3), got %v",
    result[2],
  )
  testing.expectf(
    t,
    approx_equal_f32(result[3], 0),
    "Zero vector should have length 0, got %v",
    result[3],
  )
}

@(test)
test_vector_normalize3_batch4 :: proc(t: ^testing.T) {
  // Test batch vector normalization
  v: [4][3]f32

  // Case 1: Already normalized
  v[0] = {1, 0, 0}

  // Case 2: Scale 2
  v[1] = {2, 0, 0}

  // Case 3: Arbitrary vector
  v[2] = {3, 4, 0}

  // Case 4: Diagonal vector
  v[3] = {1, 1, 1}

  // Compute reference with scalar path
  expected: [4][3]f32
  for i in 0 ..< 4 {
    expected[i] = linalg.normalize(v[i])
  }
  result := vector_normalize3_batch4(v)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      approx_equal_vec3(result[i], expected[i]),
      "Vector normalize %d: SIMD result doesn't match scalar. Got %v, expected %v",
      i,
      result[i],
      expected[i],
    )
  }

  // Verify all results are unit vectors
  for i in 0 ..< 4 {
    len := linalg.length(result[i])
    testing.expectf(
      t,
      approx_equal_f32(len, 1),
      "Normalized vector %d should have length 1, got %v",
      i,
      len,
    )
  }
}

// Benchmark data structures





@(test)
benchmark_vector_cross3 :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  Benchmark_Data :: struct {
    vectors_a: [100000][4][3]f32,
    vectors_b: [100000][4][3]f32,
  }
  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.vectors_a) {
    for j in 0 ..< 4 {
      data.vectors_a[i][j] = {f32(i + j), f32(i * 2 + j), f32(i * 3 + j)}
      data.vectors_b[i][j] = {f32(j + 1), f32(j * 2 + 1), f32(j * 3 + 1)}
    }
  }

  // Benchmark SIMD batch path
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for batch in &data_ptr.vectors_a {
        idx := i % len(data_ptr.vectors_a)
        _ = vector_cross3_batch4(
          data_ptr.vectors_a[idx],
          data_ptr.vectors_b[idx],
        )
        options.processed += 4 * size_of([3]f32)
      }
    }
    return nil
  }

  // Benchmark scalar path
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vectors_a) {
        result: [4][3]f32
        for j in 0 ..< 4 {
          result[j] = linalg.cross(
            data_ptr.vectors_a[idx][j],
            data_ptr.vectors_b[idx][j],
          )
        }
        options.processed += 4 * size_of([3]f32)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of([3]f32) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of([3]f32) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "Vector Cross Product: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}

@(test)
benchmark_quaternion_mul_vector3 :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  Benchmark_Data :: struct {
    quaternions: [100000][4]quaternion128,
    vectors:     [100000][4][3]f32,
  }
  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.quaternions) {
    for j in 0 ..< 4 {
      angle := f32(i + j) * 0.01
      data.quaternions[i][j] = linalg.quaternion_angle_axis_f32(
        angle,
        [3]f32{1, 1, 1},
      )
      data.vectors[i][j] = {f32(j + 1), f32(j * 2 + 1), f32(j * 3 + 1)}
    }
  }

  // Benchmark SIMD batch path
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.quaternions) {
        _ = quaternion_mul_vector3_batch4(
          data_ptr.quaternions[idx],
          data_ptr.vectors[idx],
        )
        options.processed += 4 * size_of([3]f32)
      }
    }
    return nil
  }

  // Benchmark scalar path
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.quaternions) {
        result: [4][3]f32
        for j in 0 ..< 4 {
          result[j] = linalg.mul(
            data_ptr.quaternions[idx][j],
            data_ptr.vectors[idx][j],
          )
        }
        options.processed += 4 * size_of([3]f32)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.quaternions) * 4 * size_of([3]f32) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.quaternions) * 4 * size_of([3]f32) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "Quaternion-Vector Mul: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}

@(test)
benchmark_vector_dot3 :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  Benchmark_Data :: struct {
    vectors_a: [100000][4][3]f32,
    vectors_b: [100000][4][3]f32,
  }
  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.vectors_a) {
    for j in 0 ..< 4 {
      data.vectors_a[i][j] = {f32(i + j), f32(i * 2 + j), f32(i * 3 + j)}
      data.vectors_b[i][j] = {f32(j + 1), f32(j * 2 + 1), f32(j * 3 + 1)}
    }
  }

  // Benchmark SIMD batch path
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vectors_a) {
        _ = vector_dot3_batch4(
          data_ptr.vectors_a[idx],
          data_ptr.vectors_b[idx],
        )
        options.processed += 4 * size_of(f32)
      }
    }
    return nil
  }

  // Benchmark scalar path
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vectors_a) {
        result: [4]f32
        for j in 0 ..< 4 {
          result[j] = linalg.dot(
            data_ptr.vectors_a[idx][j],
            data_ptr.vectors_b[idx][j],
          )
        }
        options.processed += 4 * size_of(f32)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of(f32) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of(f32) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "Vector Dot Product: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}

@(test)
benchmark_vector_length3 :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  Benchmark_Data :: struct {
    vectors_a: [100000][4][3]f32,
    vectors_b: [100000][4][3]f32,
  }
  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.vectors_a) {
    for j in 0 ..< 4 {
      data.vectors_a[i][j] = {f32(i + j), f32(i * 2 + j), f32(i * 3 + j)}
    }
  }

  // Benchmark SIMD batch path
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vectors_a) {
        _ = vector_length3_batch4(data_ptr.vectors_a[idx])
        options.processed += 4 * size_of(f32)
      }
    }
    return nil
  }

  // Benchmark scalar path
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vectors_a) {
        result: [4]f32
        for j in 0 ..< 4 {
          result[j] = linalg.length(data_ptr.vectors_a[idx][j])
        }
        options.processed += 4 * size_of(f32)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of(f32) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of(f32) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "Vector Length: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}

@(test)
benchmark_vector_normalize3 :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  Benchmark_Data :: struct {
    vectors_a: [100000][4][3]f32,
    vectors_b: [100000][4][3]f32,
  }
  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.vectors_a) {
    for j in 0 ..< 4 {
      data.vectors_a[i][j] = {f32(i + j), f32(i * 2 + j), f32(i * 3 + j)}
    }
  }

  // Benchmark SIMD batch path
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vectors_a) {
        _ = vector_normalize3_batch4(data_ptr.vectors_a[idx])
        options.processed += 4 * size_of([3]f32)
      }
    }
    return nil
  }

  // Benchmark scalar path
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vectors_a) {
        result: [4][3]f32
        for j in 0 ..< 4 {
          result[j] = linalg.normalize(data_ptr.vectors_a[idx][j])
        }
        options.processed += 4 * size_of([3]f32)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of([3]f32) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vectors_a) * 4 * size_of([3]f32) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "Vector Normalize: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}

@(test)
test_aabb_intersects_batch4 :: proc(t: ^testing.T) {
  // Test batch AABB intersection
  a: [4]geometry.Aabb
  b: [4]geometry.Aabb

  // Case 1: AABBs that intersect
  a[0] = geometry.Aabb {
    min = {0, 0, 0},
    max = {2, 2, 2},
  }
  b[0] = geometry.Aabb {
    min = {1, 1, 1},
    max = {3, 3, 3},
  }

  // Case 2: AABBs that don't intersect (separated on X axis)
  a[1] = geometry.Aabb {
    min = {0, 0, 0},
    max = {1, 1, 1},
  }
  b[1] = geometry.Aabb {
    min = {2, 0, 0},
    max = {3, 1, 1},
  }

  // Case 3: AABBs that touch (edge case)
  a[2] = geometry.Aabb {
    min = {0, 0, 0},
    max = {1, 1, 1},
  }
  b[2] = geometry.Aabb {
    min = {1, 0, 0},
    max = {2, 1, 1},
  }

  // Case 4: One AABB completely inside another
  a[3] = geometry.Aabb {
    min = {0, 0, 0},
    max = {10, 10, 10},
  }
  b[3] = geometry.Aabb {
    min = {2, 2, 2},
    max = {8, 8, 8},
  }

  // Compute reference with scalar path
  expected: [4]bool
  for i in 0 ..< 4 {
    expected[i] = geometry.aabb_intersects(a[i], b[i])
  }
  result := aabb_intersects_batch4(a, b)

  // Verify results match
  for i in 0 ..< 4 {
    testing.expectf(
      t,
      result[i] == expected[i],
      "AABB intersection %d: SIMD result doesn't match scalar. Got %v, expected %v",
      i,
      result[i],
      expected[i],
    )
  }

  // Verify specific expected results
  testing.expectf(
    t,
    result[0] == true,
    "Overlapping AABBs should intersect, got %v",
    result[0],
  )
  testing.expectf(
    t,
    result[1] == false,
    "Separated AABBs should not intersect, got %v",
    result[1],
  )
  testing.expectf(
    t,
    result[2] == true,
    "Touching AABBs should intersect, got %v",
    result[2],
  )
  testing.expectf(
    t,
    result[3] == true,
    "Nested AABBs should intersect, got %v",
    result[3],
  )
}

@(test)
benchmark_obb_to_aabb :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  Benchmark_Data :: struct {
    obbs: [100000][4]geometry.Obb,
  }
  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.obbs) {
    for j in 0 ..< 4 {
      angle := f32(i + j) * 0.01
      data.obbs[i][j] = geometry.Obb {
        center       = {f32(i + j), f32(i * 2 + j), f32(i * 3 + j)},
        half_extents = {1.5, 2.0, 2.5},
        rotation     = linalg.quaternion_angle_axis_f32(
          angle,
          [3]f32{1, 1, 1},
        ),
      }
    }
  }

  // Benchmark SIMD batch path
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    aabbs: [4]geometry.Aabb
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.obbs) {
        obb_to_aabb_batch4(data_ptr.obbs[idx], &aabbs)
        options.processed += 4 * size_of(geometry.Aabb)
      }
    }
    return nil
  }

  // Benchmark scalar path
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.obbs) {
        aabbs: [4]geometry.Aabb
        for j in 0 ..< 4 {
          aabbs[j] = geometry.obb_to_aabb(data_ptr.obbs[idx][j])
        }
        options.processed += 4 * size_of(geometry.Aabb)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.obbs) * 4 * size_of(geometry.Aabb) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.obbs) * 4 * size_of(geometry.Aabb) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "OBB to AABB: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}


@(test)
benchmark_quaternion_mul_vector3_single :: proc(t: ^testing.T) {
  Benchmark_Data :: struct {
    quaternions: [100000]quaternion128,
    vectors:     [100000][3]f32,
  }
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.quaternions) {
    angle := f32(i) * 0.01
    data.quaternions[i] = linalg.quaternion_angle_axis_f32(
      angle,
      [3]f32{1, 1, 1},
    )
    data.vectors[i] = {
      f32(i % 100 + 1),
      f32((i * 2) % 100 + 1),
      f32((i * 3) % 100 + 1),
    }
  }

  custom_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.quaternions) {
        _ = geometry.qmv(data_ptr.quaternions[idx], data_ptr.vectors[idx])
        options.processed += size_of([3]f32)
      }
    }
    return nil
  }

  linalg_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.quaternions) {
        _ = linalg.mul(data_ptr.quaternions[idx], data_ptr.vectors[idx])
        options.processed += size_of([3]f32)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(
    data,
    size_of(Benchmark_Data),
  )

  custom_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.quaternions) * size_of([3]f32) * 100,
    input = input_bytes,
    bench = custom_proc,
  }
  time.benchmark(custom_options)

  linalg_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.quaternions) * size_of([3]f32) * 100,
    input = input_bytes,
    bench = linalg_proc,
  }
  time.benchmark(linalg_options)

  speedup := f64(linalg_options.duration) / f64(custom_options.duration)
  log.infof(
    "Single Quat-Vec Mul: Custom %.2f ms (%.2f MB/s) | linalg %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(custom_options.duration) / 1_000_000,
    custom_options.megabytes_per_second,
    f64(linalg_options.duration) / 1_000_000,
    linalg_options.megabytes_per_second,
    speedup,
  )
}


@(test)
benchmark_add_faces_batch4 :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  // Benchmark data structure for EPA face operations
  Benchmark_Data :: struct {
    vertices: [25000][4][3]f32, // 4 vertices per tetrahedron
    indices:  [4][3]int, // Standard tetrahedron indices
  }

  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)

  // Standard tetrahedron face indices
  data.indices = {{0, 1, 2}, {0, 3, 1}, {0, 2, 3}, {1, 3, 2}}

  // Generate random tetrahedron vertices
  for i in 0 ..< len(data.vertices) {
    // Create random but valid tetrahedron vertices
    base := f32(i % 100)
    data.vertices[i][0] = {base, base, base}
    data.vertices[i][1] = {base + 1, base, base}
    data.vertices[i][2] = {base + 0.5, base + 1, base}
    data.vertices[i][3] = {base + 0.5, base + 0.5, base + 1}
  }

  // Benchmark SIMD batch path (add_faces_batch4)
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    faces := make([dynamic]EPAFace, 0, 4, context.temp_allocator)
    vertices := make([dynamic][3]f32, 0, 4, context.temp_allocator)

    for _ in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vertices) {
        clear(&faces)
        clear(&vertices)
        for j in 0 ..< 4 {
          append(&vertices, data_ptr.vertices[idx][j])
        }
        add_faces_batch4(&faces, &vertices, data_ptr.indices)
        options.processed += 4 * size_of(EPAFace)
      }
    }
    return nil
  }

  // Benchmark scalar path (4x add_face)
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    faces := make([dynamic]EPAFace, 0, 4, context.temp_allocator)
    vertices := make([dynamic][3]f32, 0, 4, context.temp_allocator)

    for _ in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.vertices) {
        clear(&faces)
        clear(&vertices)
        for j in 0 ..< 4 {
          append(&vertices, data_ptr.vertices[idx][j])
        }
        // Call add_face 4 times (scalar path)
        add_face(&faces, &vertices, 0, 1, 2)
        add_face(&faces, &vertices, 0, 3, 1)
        add_face(&faces, &vertices, 0, 2, 3)
        add_face(&faces, &vertices, 1, 3, 2)
        options.processed += 4 * size_of(EPAFace)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vertices) * 4 * size_of(EPAFace) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.vertices) * 4 * size_of(EPAFace) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "EPA add_faces_batch4: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}

@(test)
benchmark_aabb_intersects :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  Benchmark_Data :: struct {
    aabbs_a: [100000][4]geometry.Aabb,
    aabbs_b: [100000][4]geometry.Aabb,
  }

  // Setup test data - use heap allocation to avoid stack overflow
  data := new(Benchmark_Data)
  defer free(data)
  for i in 0 ..< len(data.aabbs_a) {
    for j in 0 ..< 4 {
      // Create some AABBs that will intersect and some that won't
      offset := f32(i % 2) * 10.0 // Some will be far apart, some close
      data.aabbs_a[i][j] = geometry.Aabb {
        min = {f32(i + j), f32(i * 2 + j), f32(i * 3 + j)},
        max = {f32(i + j) + 5, f32(i * 2 + j) + 5, f32(i * 3 + j) + 5},
      }
      data.aabbs_b[i][j] = geometry.Aabb {
        min = {
          f32(i + j) + offset,
          f32(i * 2 + j) + offset,
          f32(i * 3 + j) + offset,
        },
        max = {
          f32(i + j) + offset + 5,
          f32(i * 2 + j) + offset + 5,
          f32(i * 3 + j) + offset + 5,
        },
      }
    }
  }

  // Benchmark SIMD batch path
  simd_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.aabbs_a) {
        _ = aabb_intersects_batch4(
          data_ptr.aabbs_a[idx],
          data_ptr.aabbs_b[idx],
        )
        options.processed += 4 * size_of(bool)
      }
    }
    return nil
  }

  // Benchmark scalar path
  scalar_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    data_ptr := cast(^Benchmark_Data)raw_data(options.input)
    for i in 0 ..< options.rounds {
      for idx in 0 ..< len(data_ptr.aabbs_a) {
        result: [4]bool
        for j in 0 ..< 4 {
          result[j] = geometry.aabb_intersects(
            data_ptr.aabbs_a[idx][j],
            data_ptr.aabbs_b[idx][j],
          )
        }
        options.processed += 4 * size_of(bool)
      }
    }
    return nil
  }

  input_bytes := slice.bytes_from_ptr(data, size_of(Benchmark_Data))

  // Run SIMD benchmark
  simd_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.aabbs_a) * 4 * size_of(bool) * 100,
    input = input_bytes,
    bench = simd_proc,
  }
  time.benchmark(simd_options)

  // Run scalar benchmark
  scalar_options := &time.Benchmark_Options {
    rounds = 100,
    bytes = len(data.aabbs_a) * 4 * size_of(bool) * 100,
    input = input_bytes,
    bench = scalar_proc,
  }
  time.benchmark(scalar_options)

  speedup := f64(scalar_options.duration) / f64(simd_options.duration)
  log.infof(
    "AABB Intersects: SIMD %.2f ms (%.2f MB/s) | Scalar %.2f ms (%.2f MB/s) | Speedup: %.2fx",
    f64(simd_options.duration) / 1_000_000,
    simd_options.megabytes_per_second,
    f64(scalar_options.duration) / 1_000_000,
    scalar_options.megabytes_per_second,
    speedup,
  )
}
