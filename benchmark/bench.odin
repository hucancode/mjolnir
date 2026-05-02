package benchmark

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

Record :: struct {
  name:  string,
  unit:  string,
  value: f64,
  extra: string,
}

Bench :: struct {
  records: [dynamic]Record,
}

destroy :: proc(b: ^Bench) {
  for r in b.records {
    delete(r.name)
    delete(r.extra)
  }
  delete(b.records)
}

emit :: proc(b: ^Bench, name: string, unit: string, value: f64, extra := "") {
  append(
    &b.records,
    Record {
      name = strings.clone(name),
      unit = unit,
      value = value,
      extra = strings.clone(extra),
    },
  )
}

run_repeat :: proc(
  b: ^Bench,
  name: string,
  unit: string,
  iters: int,
  body: proc(),
) {
  samples := make([]f64, iters, context.temp_allocator)
  for i in 0 ..< iters {
    t := time.tick_now()
    body()
    samples[i] = f64(time.tick_since(t)) / f64(time.Millisecond)
  }
  summarize(b, name, unit, samples)
}

summarize :: proc(b: ^Bench, name: string, unit: string, samples: []f64) {
  if len(samples) == 0 do return
  sorted := slice.clone(samples, context.temp_allocator)
  slice.sort(sorted)
  median := sorted[len(sorted) / 2]
  p99_idx := (len(sorted) * 99) / 100
  if p99_idx >= len(sorted) do p99_idx = len(sorted) - 1
  p99 := sorted[p99_idx]
  min_v := sorted[0]
  max_v := sorted[len(sorted) - 1]
  sum: f64 = 0
  for v in samples do sum += v
  mean := sum / f64(len(samples))
  extra := fmt.tprintf(
    "p99=%.4f min=%.4f max=%.4f mean=%.4f n=%d",
    p99,
    min_v,
    max_v,
    mean,
    len(samples),
  )
  emit(b, name, unit, median, extra)
}

marshal :: proc(b: ^Bench, allocator := context.allocator) -> ([]byte, json.Marshal_Error) {
  return json.marshal(
    b.records,
    {pretty = true, use_spaces = true, spaces = 2},
    allocator,
  )
}
