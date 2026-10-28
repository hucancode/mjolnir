// An API and examples reference generator for any Odin project:
//   odin run docs/gen -- -src=<dir> -out=<dir> [-examples=<dir>] [-media=<dir>] [-name=<project>] [-url=<repo>]
// Writes <out>/api.json (every package under -src, from `odin doc`) and <out>/examples.json
// (every <examples>/<category>/<name>/main.odin, its leading comment the description; a web
// build at <out>/<name>.wasm and media at <media>/videos/<name>.mp4 and <media>/posters/<name>.jpg
// noted); the pages fetch them. A package's doc.odin may name its layer after the package clause
// (`// Layer N: name`): once one does, every one must, and imports must point to lower layers.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

SECTIONS := [?]string{"constants", "variables", "procedures", "types", "procedure groups"}

Sym :: struct {
  sig: string,
  doc: string,
}

Section :: struct {
  name: string,
  syms: []Sym,
}

Pkg :: struct {
  path:       string,
  doc:        string,
  layer:      int, // from the `// Layer N: name` line after the package clause; -1 for none
  layer_name: string,
  notes:      string, // the rest of the comments after the package clause
  imports:    []string, // the packages under -src it imports
  sections:   []Section,
}

// What api.json holds.
Api :: struct {
  project:  string,
  url:      string,
  root:     string, // -src, which package paths start with
  packages: []Pkg,
}

// What examples.json holds.
Examples :: struct {
  project:  string,
  url:      string,
  examples: []Example,
}

// The command line.
Options :: struct {
  src, out, examples, media, name, url: string,
}

options: Options

Example :: struct {
  name:     string,
  category: string, // the examples/<category> folder it lives in
  desc:     string,
  source:   string,
  video:    bool,
  wasm:     bool, // a WebGPU build exists at <wasm_dir>/<name>.wasm (the site's data/)
}

// raw symbol straight out of `odin doc`, its doc still in lines
Raw_Sym :: struct {
  sig: string,
  doc: [dynamic]string,
}

Raw_Section :: struct {
  name: string,
  syms: [dynamic]Raw_Sym,
}

die :: proc(msg: string, args: ..any) -> ! {
  fmt.eprintfln(msg, ..args)
  os.exit(1)
}

run :: proc(args: ..string) -> string {
  state, out, errout, err := os.process_exec({command = args}, context.allocator)
  if err != nil || !state.success {
    die("command failed: %v\n%s", args, string(errout))
  }
  return string(out)
}

read :: proc(path: string) -> string {
  data, err := os.read_entire_file(path, context.allocator)
  if err != nil do die("cannot read %s: %v", path, err)
  return string(data)
}

write :: proc(path, content: string) {
  if err := os.write_entire_file(path, content); err != nil {
    die("cannot write %s: %v", path, err)
  }
}

// `odin doc` output is tab-indented: 1 tab = package doc / section header, 2 = symbol, 3+ = symbol doc
parse_doc :: proc(text: string) -> (doc: [dynamic]string, sections: [dynamic]Raw_Section) {
  cur := -1
  sym := false
  text := text
  first := true
  for line in strings.split_lines_iterator(&text) {
    if first {first = false; continue} // "package x"
    tabs := 0
    for tabs < len(line) && line[tabs] == '\t' do tabs += 1
    body := strings.trim_space(line)
    if body == "" do continue
    switch {
    case tabs == 1:
      if body == "fullpath:" || body == "files:" {
        cur, sym = -1, false
        continue
      }
      if slice.contains(SECTIONS[:], body) {
        append(&sections, Raw_Section{name = body})
        cur, sym = len(sections) - 1, false
        continue
      }
      if cur < 0 do append(&doc, body)
    case cur >= 0 && tabs == 2:
      s := Raw_Sym{sig = body}
      // drop the trailing "/* pkg:file.odin!offset */"
      if strings.has_suffix(body, " */") {
        if i := strings.last_index(body, "/* "); i >= 0 {
          s.sig = strings.trim_right_space(body[:i])
        }
      }
      append(&sections[cur].syms, s)
      sym = true
    case cur >= 0 && sym && tabs > 2:
      syms := &sections[cur].syms
      append(&syms[len(syms) - 1].doc, body)
    }
  }
  return
}

// Every directory under root holding .odin files.
package_dirs :: proc(root: string) -> []string {
  dirs: [dynamic]string
  walk :: proc(dir: string, dirs: ^[dynamic]string) {
    infos, err := os.read_all_directory_by_path(dir, context.allocator)
    if err != nil do die("cannot list %s: %v", dir, err)
    has_source := false
    for fi in infos {
      if fi.type == .Directory {
        sub, _ := filepath.join({dir, fi.name})
        walk(sub, dirs)
      } else if strings.has_suffix(fi.name, ".odin") {
        has_source = true
      }
    }
    if has_source do append(dirs, dir)
  }
  walk(root, &dirs)
  slice.sort(dirs[:])
  return dirs[:]
}

// A struct's anonymous `using _: X` is its private state: the reference shows the public
// fields alone.
drop_private_using :: proc(sig: string) -> string {
  sig := sig
  for {
    start := strings.index(sig, "using _: ")
    if start < 0 do return sig
    end := start + len("using _: ")
    for end < len(sig) && is_ident(sig[end:end + 1]) do end += 1
    if strings.has_prefix(sig[end:], ", ") {
      end += 2
    } else if start >= 2 && sig[start - 2:start] == ", " {
      start -= 2
    }
    sig = strings.concatenate({sig[:start], sig[end:]})
  }
}

// A package as `odin doc` lists it, its re-exports not expanded yet (expand_reexports).
load_pkg :: proc(path: string) -> Pkg {
  // test files are #+private, so `odin doc` leaves their symbols out
  doc, raw := parse_doc(run("odin", "doc", path))
  source := scan_sources(path)
  sections: [dynamic]Section
  for r in raw {
    syms: [dynamic]Sym
    seen: map[string]int
    for s in r.syms {
      sig := drop_private_using(s.sig)
      sig = rename_alias(sig, source.aliases, &seen)
      append(&syms, Sym{sig = sig, doc = strings.join(s.doc[:], "\n")})
    }
    if len(syms) > 0 do append(&sections, Section{name = r.name, syms = syms[:]})
  }
  p := Pkg{path = path, doc = strings.join(doc[:], "\n"), sections = sections[:], imports = source.imports}
  load_layer(&p)
  return p
}

// The layer line and notes: the comments after the package clause of the package's doc.odin.
load_layer :: proc(p: ^Pkg) {
  p.layer = -1
  doc_path := strings.concatenate({p.path, "/doc.odin"})
  if !os.exists(doc_path) do return
  source := read(doc_path)
  notes: [dynamic]string
  after := false
  for line in strings.split_lines_iterator(&source) {
    if !after {
      after = strings.has_prefix(line, "package ")
      continue
    }
    text := strings.trim_space(line)
    if text == "" {
      if len(notes) > 0 && notes[len(notes) - 1] != "" do append(&notes, "")
      continue
    }
    if !strings.has_prefix(text, "//") do break
    text = strings.trim_prefix(text[2:], " ")
    if p.layer_name == "" && strings.has_prefix(text, "Layer ") {
      colon := strings.index(text, ": ")
      n, is_number := strconv.parse_int(text[len("Layer "):max(colon, 0)], 10)
      if colon < 0 || !is_number || n < 0 do die("%s: bad layer line %q", p.path, text)
      p.layer, p.layer_name = n, text[colon + 2:]
      continue
    }
    append(&notes, text)
  }
  for len(notes) > 0 && notes[len(notes) - 1] == "" do pop(&notes)
  p.notes = strings.join(notes[:], "\n")
}

// What a package's sources (tests aside) say beyond `odin doc`: the packages under -src they
// import, as paths, and the names of their `alias :: target` procedure aliases, by target
// (`odin doc` lists an alias under its target's name, so the reference names the repeats after
// the aliases).
Sources :: struct {
  imports: []string,
  aliases: map[string][dynamic]string,
}

scan_sources :: proc(path: string) -> (out: Sources) {
  imports: [dynamic]string
  infos, err := os.read_all_directory_by_path(path, context.allocator)
  if err != nil do die("cannot list %s: %v", path, err)
  for fi in infos {
    if !strings.has_suffix(fi.name, ".odin") || strings.has_suffix(fi.name, "_test.odin") do continue
    source := read(fi.fullpath)
    for line in strings.split_lines_iterator(&source) {
      if strings.has_prefix(line, "import ") {
        open := strings.index_byte(line, '"')
        close := strings.last_index_byte(line, '"')
        if open < 0 || close <= open do continue
        target := line[open + 1:close]
        if strings.contains_rune(target, ':') {continue} // core:, vendor:
        dir, _ := filepath.join({path, target})
        if !slice.contains(imports[:], dir) do append(&imports, dir)
        continue
      }
      parts := strings.split(line, " :: ", context.temp_allocator)
      if len(parts) != 2 || !is_ident(parts[0]) || !is_ident(parts[1]) do continue
      // lower case on both sides: a procedure, not a type or constant
      if parts[0][0] < 'a' || parts[0][0] > 'z' || parts[1][0] < 'a' || parts[1][0] > 'z' do continue
      if parts[1] not_in out.aliases do out.aliases[parts[1]] = {}
      append(&out.aliases[parts[1]], parts[0])
    }
  }
  slice.sort(imports[:])
  out.imports = imports[:]
  return
}

// Once a package names its layer every one must; then a package imports only from the layers
// below its own and from under -src, and every layer number has one name.
check_layers :: proc(pkgs: []Pkg) {
  layered := false
  for p in pkgs do layered ||= p.layer >= 0
  if !layered do return
  names: map[int]string
  index: map[string]int
  for p, i in pkgs {
    if p.layer < 0 do die("%s/doc.odin: no `// Layer N: name` line after the package clause", p.path)
    if name, seen := names[p.layer]; seen && name != p.layer_name do die("layer %d is both %q and %q (%s)", p.layer, name, p.layer_name, p.path)
    names[p.layer] = p.layer_name
    index[p.path] = i
  }
  for p in pkgs do for imp in p.imports {
    q, inside := index[imp]
    if !inside do die("%s imports %s, outside %s", p.path, imp, options.src)
    if pkgs[q].layer >= p.layer do die("%s (layer %d) imports %s (layer %d)", p.path, p.layer, imp, pkgs[q].layer)
  }
}

is_ident :: proc(s: string) -> bool {
  if len(s) == 0 do return false
  for c in s {
    if !(c == '_' || (c >= '0' && c <= '9') || (c | 0x20 >= 'a' && c | 0x20 <= 'z')) do return false
  }
  return true
}

// The n-th repeat of a target's signature names its n-th alias.
rename_alias :: proc(sig: string, aliases: map[string][dynamic]string, seen: ^map[string]int) -> string {
  end := strings.index(sig, " :: ")
  if end < 0 do return sig
  name := sig[:end]
  names, ok := aliases[name]
  if !ok do return sig
  n := seen[name]
  seen[name] = n + 1
  if n == 0 || n > len(names) do return sig
  return strings.concatenate({names[n - 1], sig[end:]})
}

// `X :: pkg.Y`, a name a package takes from another one under -src it imports, shows what Y is.
expand_reexports :: proc(pkgs: []Pkg) {
  // per package path, each symbol's definition, the ` :: ...` after its name
  definitions: map[string]map[string]string
  for p in pkgs {
    defs: map[string]string
    for sec in p.sections do for s in sec.syms do if i := strings.index(s.sig, " :: "); i >= 0 do defs[s.sig[:i]] = s.sig[i:]
    definitions[p.path] = defs
  }
  for p in pkgs do for sec in p.sections do for &s in sec.syms {
    end := strings.index(s.sig, " :: ")
    if end < 0 do continue
    target := s.sig[end + len(" :: "):]
    dot := strings.index_byte(target, '.')
    if dot < 0 || !is_ident(target[:dot]) || !is_ident(target[dot + 1:]) do continue
    for imp in p.imports do if filepath.base(imp) == target[:dot] {
      if definition, found := definitions[imp][target[dot + 1:]]; found do s.sig = strings.concatenate({s.sig[:end], definition})
    }
  }
}

// The examples by category, then name, with their web builds (`<name>.wasm` in wasm_dir) and
// videos.
load_examples :: proc(root, wasm_dir, media: string) -> []Example {
  if root == "" do return nil
  categories, err := os.read_all_directory_by_path(root, context.allocator)
  if err != nil do die("cannot list examples: %v", err)
  out: [dynamic]Example
  for category in categories {
    if category.type != .Directory do continue
    infos, list_err := os.read_all_directory_by_path(category.fullpath, context.allocator)
    if list_err != nil do die("cannot list %s: %v", category.name, list_err)
    for fi in infos {
      main_path, _ := filepath.join({root, category.name, fi.name, "main.odin"})
      if fi.type != .Directory || !os.exists(main_path) do continue
      source := read(main_path)
      // description = the leading `//` lines up to the first sentence's end; credits follow
      desc: [dynamic]string
      lines := source
      for line in strings.split_lines_iterator(&lines) {
        if !strings.has_prefix(line, "//") do break
        text := strings.trim_space(line[2:])
        append(&desc, text)
        if strings.has_suffix(text, ".") || strings.has_suffix(text, "!") do break
      }
      video_path, _ := filepath.join({media, "videos", fmt.tprintf("%s.mp4", fi.name)})
      wasm_path, _ := filepath.join({wasm_dir, fmt.tprintf("%s.wasm", fi.name)})
      append(&out, Example {
        name     = fi.name,
        category = category.name,
        desc     = strings.join(desc[:], " "),
        source   = source,
        video    = media != "" && os.exists(video_path),
        wasm     = os.exists(wasm_path),
      })
    }
  }
  slice.sort_by(out[:], proc(a, b: Example) -> bool {
    if a.category != b.category do return a.category < b.category
    return a.name < b.name
  })
  return out[:]
}

// Warns of examples without a video or a poster, and of media of no example.
check_media :: proc(examples: []Example, media: string) {
  if media == "" do return
  for e in examples {
    if !e.video do fmt.eprintfln("warning: example %s has no video", e.name)
    poster, _ := filepath.join({media, "posters", fmt.tprintf("%s.jpg", e.name)})
    if e.video && !os.exists(poster) do fmt.eprintfln("warning: example %s has a video but no poster", e.name)
  }
  for dir in ([]string{"videos", "posters"}) {
    path, _ := filepath.join({media, dir})
    infos, err := os.read_all_directory_by_path(path, context.allocator)
    if err != nil do continue
    for fi in infos {
      name := filepath.stem(fi.name)
      found := false
      for e in examples do if e.name == name do found = true
      if !found do fmt.eprintfln("warning: %s/%s belongs to no example", path, fi.name)
    }
  }
}

emit :: proc(path: string, value: any) {
  data, err := json.marshal(value, {}, context.allocator)
  if err != nil do die("cannot encode %s: %v", path, err)
  write(path, string(data))
}

USAGE :: "usage: gen -src=<dir> -out=<dir> [-examples=<dir>] [-media=<dir>] [-name=<project>] [-url=<repo>]"

main :: proc() {
  for arg in os.args[1:] {
    eq := strings.index_byte(arg, '=')
    if eq < 0 do die(USAGE)
    value := arg[eq + 1:]
    switch arg[:eq] {
    case "-src":
      options.src = value
    case "-out":
      options.out = value
    case "-examples":
      options.examples = value
    case "-media":
      options.media = value
    case "-name":
      options.name = value
    case "-url":
      options.url = value
    case:
      die(USAGE)
    }
  }
  if options.src == "" || options.out == "" do die(USAGE)
  if options.name == "" do options.name = filepath.base(options.src)
  if err := os.make_directory_all(options.out); err != nil && err != os.General_Error.Exist {
    die("cannot create %s: %v", options.out, err)
  }
  pkgs: [dynamic]Pkg
  for d in package_dirs(options.src) do append(&pkgs, load_pkg(d))
  check_layers(pkgs[:])
  expand_reexports(pkgs[:])
  emit(strings.concatenate({options.out, "/api.json"}), Api{options.name, options.url, options.src, pkgs[:]})
  examples := load_examples(options.examples, options.out, options.media)
  check_media(examples, options.media)
  emit(strings.concatenate({options.out, "/examples.json"}), Examples{options.name, options.url, examples})
  fmt.printfln("wrote %d packages, %d examples to %s", len(pkgs), len(examples), options.out)
}
