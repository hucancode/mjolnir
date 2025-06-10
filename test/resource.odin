package tests

import "../mjolnir/resource"
import "core:testing"

TestData :: struct {
    value: i32,
    name: string,
}

@(test)
test_resource_pool_basic_allocation :: proc(t: ^testing.T) {
    pool: resource.Pool(TestData)
    resource.pool_init(&pool)
    defer resource.pool_deinit(pool, proc(data: ^TestData) {})

    handle, data := resource.alloc(&pool)
    testing.expect(t, data != nil)
    testing.expect_value(t, handle.generation, 1)

    data.value = 42
    retrieved := resource.get(pool, handle)
    testing.expect_value(t, retrieved.value, 42)
}

@(test)
test_resource_pool_handle_invalidation :: proc(t: ^testing.T) {
    pool: resource.Pool(TestData)
    resource.pool_init(&pool)
    defer resource.pool_deinit(pool, proc(data: ^TestData) {})

    handle, _ := resource.alloc(&pool)
    resource.free(&pool, handle)

    retrieved, found := resource.get(pool, handle)
    testing.expect(t, !found)
    testing.expect(t, retrieved == nil)
}

@(test)
test_resource_pool_generation_increment :: proc(t: ^testing.T) {
    pool: resource.Pool(TestData)
    resource.pool_init(&pool)
    defer resource.pool_deinit(pool, proc(data: ^TestData) {})
    handle1, _ := resource.alloc(&pool)
    resource.free(&pool, handle1)
    handle2, _ := resource.alloc(&pool)
    testing.expect_value(t, handle2.index, handle1.index) // same index reused
    testing.expect(t, handle2.generation > handle1.generation) // generation incremented
}

@(test)
test_invalid_resource_handles :: proc(t: ^testing.T) {
    pool: resource.Pool(int)
    resource.pool_init(&pool)
    defer resource.pool_deinit(pool, proc(data: ^int) {})
    invalid_handle := resource.Handle{index = 9999, generation = 1}
    data, found := resource.get(pool, invalid_handle)
    testing.expect(t, !found)
    testing.expect(t, data == nil)
}
