package benchmark

import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
  out_path := "bench.json"
  filter := ""
  for arg, i in os.args {
    if i == 0 do continue
    if strings.has_prefix(arg, "--out=") {
      out_path = arg[len("--out="):]
    } else if strings.has_prefix(arg, "--filter=") {
      filter = arg[len("--filter="):]
    } else if arg == "--help" || arg == "-h" {
      fmt.println(
        "mjolnir-bench [--out=PATH] [--filter=SUBSTRING]\n  default out: bench.json",
      )
      return
    }
  }

  groups := []struct {
    name: string,
    run:  proc(b: ^Bench),
  } {
    {"physics_simulation", bench_physics_simulation},
    {"physics_raycast",    bench_physics_raycast},
    {"simd_obb",           bench_simd_obb_to_aabb},
    {"bvh",                bench_bvh_build},
  }

  bench: Bench
  defer destroy(&bench)

  for g in groups {
    if filter != "" && !strings.contains(g.name, filter) do continue
    fmt.eprintf("[bench] running %s\n", g.name)
    g.run(&bench)
    free_all(context.temp_allocator)
  }

  data, merr := marshal(&bench)
  if merr != nil {
    fmt.eprintfln("marshal failed: %v", merr)
    os.exit(1)
  }
  defer delete(data)
  if err := os.write_entire_file_from_bytes(out_path, data); err != nil {
    fmt.eprintfln("write %s failed: %v", out_path, err)
    os.exit(1)
  }
  fmt.eprintf("[bench] %d records → %s\n", len(bench.records), out_path)
}
