// Docs data generator. Run from the repo root: `odin run docs/gen -- docs/build/data`
// Writes api.json (from `odin doc`) and examples.json (from examples/, and the example web builds
// already in the output dir); the pages fetch them.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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
	layer:      int, // from the `// Layer N: name` line after the package clause
	layer_name: string,
	notes:      string, // the rest of the comments after the package clause
	imports:    []string, // the engine packages it imports
	sections:   []Section,
}

Example :: struct {
	name:     string,
	category: string, // the examples/<category> folder it lives in
	desc:   string,
	source: string,
	video:  bool,
	wasm:   bool, // a WebGPU build exists at live/<name>.wasm
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
	if err != nil {die("cannot read %s: %v", path, err)}
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
		for tabs < len(line) && line[tabs] == '\t' {tabs += 1}
		body := strings.trim_space(line)
		if body == "" {continue}
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
			if cur < 0 {append(&doc, body)}
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

package_dirs :: proc() -> []string {
	seen: map[string]struct{}
	dirs: [dynamic]string
	for f in strings.split_lines(run("git", "ls-files", "mjolnir")) {
		if !strings.has_suffix(f, ".odin") {continue}
		d, _ := filepath.split(f)
		d = strings.trim_right(d, "/")
		if d not_in seen {
			seen[d] = {}
			append(&dirs, d)
		}
	}
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
		for end < len(sig) && (sig[end] == '_' || (sig[end] >= '0' && sig[end] <= '9') || (sig[end] | 0x20 >= 'a' && sig[end] | 0x20 <= 'z')) {end += 1}
		if strings.has_prefix(sig[end:], ", ") {
			end += 2
		} else if start >= 2 && sig[start - 2:start] == ", " {
			start -= 2
		}
		sig = strings.concatenate({sig[:start], sig[end:]})
	}
}

load_pkg :: proc(path: string) -> Pkg {
	// test files are #+private, so `odin doc` leaves their symbols out
	doc, raw := parse_doc(run("odin", "doc", path))
	aliases := proc_aliases(path)
	sections: [dynamic]Section
	for r in raw {
		syms: [dynamic]Sym
		seen: map[string]int
		for s in r.syms {
			sig := drop_private_using(s.sig)
			sig = rename_alias(sig, aliases, &seen)
			sig = expand_reexport(sig)
			append(&syms, Sym{sig = sig, doc = strings.join(s.doc[:], "\n")})
		}
		if len(syms) > 0 {append(&sections, Section{name = r.name, syms = syms[:]})}
	}
	p := Pkg{path = path, doc = strings.join(doc[:], "\n"), sections = sections[:]}
	load_layer(&p)
	p.imports = imports(path)
	return p
}

// The layer line and notes: the comments after the package clause of the package's doc.odin.
load_layer :: proc(p: ^Pkg) {
	source := read(strings.concatenate({p.path, "/doc.odin"}))
	notes: [dynamic]string
	after := false
	for line in strings.split_lines_iterator(&source) {
		if !after {
			after = strings.has_prefix(line, "package ")
			continue
		}
		text := strings.trim_space(line)
		if text == "" {
			if len(notes) > 0 && notes[len(notes) - 1] != "" {append(&notes, "")}
			continue
		}
		if !strings.has_prefix(text, "//") {break}
		text = strings.trim_prefix(text[2:], " ")
		if p.layer_name == "" && strings.has_prefix(text, "Layer ") {
			colon := strings.index(text, ": ")
			if colon < 0 || colon != 7 || text[6] < '0' || text[6] > '9' {die("%s: bad layer line %q", p.path, text)}
			p.layer, p.layer_name = int(text[6] - '0'), text[colon + 2:]
			continue
		}
		append(&notes, text)
	}
	if p.layer_name == "" {die("%s/doc.odin: no `// Layer N: name` line after the package clause", p.path)}
	for len(notes) > 0 && notes[len(notes) - 1] == "" {pop(&notes)}
	p.notes = strings.join(notes[:], "\n")
}

// The engine packages a package's sources (tests aside) import, as repo paths.
imports :: proc(path: string) -> []string {
	out: [dynamic]string
	infos, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {die("cannot list %s: %v", path, err)}
	for fi in infos {
		if !strings.has_suffix(fi.name, ".odin") || strings.has_suffix(fi.name, "_test.odin") {continue}
		source := read(fi.fullpath)
		for line in strings.split_lines_iterator(&source) {
			if !strings.has_prefix(line, "import ") {continue}
			open := strings.index_byte(line, '"')
			close := strings.last_index_byte(line, '"')
			if open < 0 || close <= open {continue}
			target := line[open + 1:close]
			if strings.contains_rune(target, ':') {continue} // core:, vendor:
			dir, _ := filepath.join({path, target})
			if !slice.contains(out[:], dir) {append(&out, dir)}
		}
	}
	slice.sort(out[:])
	return out[:]
}

// A package imports only from the layers below its own, and every layer number has one name.
check_layers :: proc(pkgs: []Pkg) {
	for p in pkgs {
		found := 0
		for q in pkgs {
			if p.layer == q.layer && p.layer_name != q.layer_name {
				die("layer %d is %q in %s but %q in %s", p.layer, p.layer_name, p.path, q.layer_name, q.path)
			}
			if !slice.contains(p.imports, q.path) {continue}
			if q.layer >= p.layer {die("%s (layer %d) imports %s (layer %d)", p.path, p.layer, q.path, q.layer)}
			found += 1
		}
		if found != len(p.imports) {die("%s imports a package outside the engine: %v", p.path, p.imports)}
	}
}

// The names of the package's `alias :: target` procedure aliases, by target: `odin doc` lists an
// alias under its target's name, so the reference names the repeats after the aliases.
proc_aliases :: proc(path: string) -> map[string][dynamic]string {
	aliases: map[string][dynamic]string
	infos, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {return aliases}
	for fi in infos {
		if !strings.has_suffix(fi.name, ".odin") || strings.has_suffix(fi.name, "_test.odin") {continue}
		source := read(fi.fullpath)
		for line in strings.split_lines_iterator(&source) {
			parts := strings.split(line, " :: ", context.temp_allocator)
			if len(parts) != 2 || !is_ident(parts[0]) || !is_ident(parts[1]) {continue}
			// lower case on both sides: a procedure, not a type or constant
			if parts[0][0] < 'a' || parts[0][0] > 'z' || parts[1][0] < 'a' || parts[1][0] > 'z' {continue}
			if parts[1] not_in aliases {aliases[parts[1]] = {}}
			append(&aliases[parts[1]], parts[0])
		}
	}
	return aliases
}

is_ident :: proc(s: string) -> bool {
	if len(s) == 0 {return false}
	for c in s {
		if !(c == '_' || (c >= '0' && c <= '9') || (c | 0x20 >= 'a' && c | 0x20 <= 'z')) {return false}
	}
	return true
}

// The n-th repeat of a target's signature names its n-th alias.
rename_alias :: proc(sig: string, aliases: map[string][dynamic]string, seen: ^map[string]int) -> string {
	end := strings.index(sig, " :: ")
	if end < 0 {return sig}
	name := sig[:end]
	names, ok := aliases[name]
	if !ok {return sig}
	n := seen[name]
	seen[name] = n + 1
	if n == 0 || n > len(names) {return sig}
	return strings.concatenate({names[n - 1], sig[end:]})
}

// `X :: rhi.Y`, a type render takes from rhi, shows what Y is.
expand_reexport :: proc(sig: string) -> string {
	@(static) rhi: map[string]string
	end := strings.index(sig, " :: rhi.")
	if end < 0 {return sig}
	if len(rhi) == 0 {
		_, raw := parse_doc(run("odin", "doc", "mjolnir/render/rhi"))
		for r in raw do for s in r.syms {
			if i := strings.index(s.sig, " :: "); i >= 0 {rhi[s.sig[:i]] = s.sig[i:]}
		}
	}
	definition, ok := rhi[sig[end + len(" :: rhi."):]]
	if !ok {return sig}
	return strings.concatenate({sig[:end], definition})
}

// The examples with their web builds, `<name>.wasm` in wasm_dir.
load_examples :: proc(wasm_dir: string) -> []Example {
	categories, err := os.read_all_directory_by_path("examples", context.allocator)
	if err != nil {die("cannot list examples: %v", err)}
	out: [dynamic]Example
	for category in categories {
	if category.type != .Directory {continue}
	infos, err := os.read_all_directory_by_path(category.fullpath, context.allocator)
	if err != nil {die("cannot list %s: %v", category.name, err)}
	for fi in infos {
		main_path, _ := filepath.join({"examples", category.name, fi.name, "main.odin"})
		if fi.type != .Directory || !os.exists(main_path) {continue}
		source := read(main_path)
		// description = the leading block of `//` comment lines
		desc: [dynamic]string
		lines := source
		for line in strings.split_lines_iterator(&lines) {
			if !strings.has_prefix(line, "//") {break}
			append(&desc, strings.trim_left_space(line[2:]))
		}
		video_path, _ := filepath.join({"docs", "site", "videos", fmt.tprintf("%s.mp4", fi.name)})
		wasm_path, _ := filepath.join({wasm_dir, fmt.tprintf("%s.wasm", fi.name)})
		append(&out, Example{
			name = fi.name,
			category = category.name,
			desc = strings.join(desc[:], " "),
			source = source,
			video = os.exists(video_path),
			wasm = os.exists(wasm_path),
		})
	}
	}
	// basic, creative, interactive; cube first as the hello world, the rest alphabetical
	rank :: proc(category: string) -> int {
		switch category {
		case "basic": return 0
		case "creative": return 1
		}
		return 2
	}
	slice.sort_by(out[:], proc(a, b: Example) -> bool {
		if a.category != b.category {return rank(a.category) < rank(b.category)}
		if (a.name == "cube") != (b.name == "cube") {return a.name == "cube"}
		return a.name < b.name
	})
	return out[:]
}

emit :: proc(path: string, value: any) {
	data, err := json.marshal(value, {}, context.allocator)
	if err != nil {die("cannot encode %s: %v", path, err)}
	write(path, string(data))
}

main :: proc() {
	if len(os.args) != 2 {die("usage: gen <output dir>")}
	out := os.args[1]

	if err := os.make_directory_all(out); err != nil && err != os.General_Error.Exist {
		die("cannot create %s: %v", out, err)
	}

	pkgs: [dynamic]Pkg
	for d in package_dirs() {append(&pkgs, load_pkg(d))}
	check_layers(pkgs[:])
	emit(strings.concatenate({out, "/api.json"}), pkgs[:])
	examples := load_examples(out)
	emit(strings.concatenate({out, "/examples.json"}), examples)
	fmt.printfln("wrote %d packages, %d examples to %s", len(pkgs), len(examples), out)
}
