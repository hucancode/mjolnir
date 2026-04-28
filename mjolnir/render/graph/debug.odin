package graph

import "core:fmt"
import "core:os"
import "core:strings"

graph_dump_dot :: proc(g: ^Graph, path: string) -> bool {
  b: strings.Builder
  strings.builder_init(&b)
  defer strings.builder_destroy(&b)
  fmt.sbprintln(&b, "digraph RenderGraph {")
  fmt.sbprintln(&b, "  rankdir=LR;")
  fmt.sbprintln(&b, "  node [shape=box, style=filled];")
  for &p, i in g.passes {
    color := p.culled ? "lightgray" : "orange"
    fmt.sbprintfln(
      &b,
      "  P%d [label=\"%s\\n(%v)\", fillcolor=%s];",
      i,
      p.name,
      p.kind,
      color,
    )
  }
  for &r, i in g.resources {
    name: string
    switch d in r.desc {
    case ImageDesc:
      name = d.name
    case BufferDesc:
      name = d.name
    }
    color := r.imported ? "lightsteelblue" : "skyblue"
    fmt.sbprintfln(
      &b,
      "  R%d [label=\"%s\", shape=ellipse, fillcolor=%s];",
      i,
      name,
      color,
    )
  }
  for &p, i in g.passes {
    for rd in p.reads {
      fmt.sbprintfln(&b, "  R%d -> P%d [label=\"%v\"];", rd.resource, i, rd.kind)
    }
    for w in p.writes {
      fmt.sbprintfln(&b, "  P%d -> R%d [label=\"%v\"];", i, w.resource, w.kind)
    }
  }
  fmt.sbprintln(&b, "}")
  return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}
