package tests

import "core:testing"
import "core:log"
import "core:slice"
import "core:mem"
import "core:time"
import "core:thread"
import "core:sync"
import "core:math"

// @(test)
test_temp_allocator_real_thread_race_condition :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 3 * time.Second)
    Data :: struct {
      sum: f32,
    }
    thread_data : Data
    // Thread 1: Allocates 100 floats, waits 1s, then reads them
    thread1_proc :: proc(t: ^thread.Thread) {
        td := cast(^Data)t.data
        data := make([]f32, 100, context.temp_allocator)
        defer free_all(context.temp_allocator)
        slice.fill(data, 1.0)
        log.info("Thread 1: Allocated 100 floats set to 1.0, waiting 1 second...")
        time.sleep(1000 * time.Millisecond)
        sum := slice.reduce(data, f32(0.0), proc(acc:f32, x:f32) -> f32 {
            return acc + x
        })
        td.sum = sum
    }

    // Thread 2: Allocates 100 floats, waits 0.5s, then frees all
    thread2_proc :: proc(t: ^thread.Thread) {
        data := make([]f32, 100, context.temp_allocator)
        // defer free_all(context.temp_allocator)
        slice.fill(data, 2.0)
        log.info("Thread 2: Allocated 100 floats, waiting 0.5 seconds...")
        time.sleep(500 * time.Millisecond)
    }

    t1 := thread.create(thread1_proc)
    t2 := thread.create(thread2_proc)
    t1.data = &thread_data
    log.info("Starting both threads...")
    thread.start(t1)
    thread.start(t2)
    thread.join(t1)
    thread.join(t2)
    testing.expectf(t, math.abs(thread_data.sum - 100.0) < math.F32_EPSILON, "sum (%v) must be 100.0", thread_data.sum)
    thread.destroy(t1)
    thread.destroy(t2)
}
