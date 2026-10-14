// Docs data generator. Run from the repo root: `odin run docs/gen -- docs/build/data`
// Writes api.js (from `odin doc`) and examples.js (from examples/), each assigning a global for the static pages.
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
	path:     string,
	doc:      string,
	sections: []Section,
}

Example :: struct {
	name:   string,
	desc:   string,
	source: string,
	video:  bool,
}

// raw symbol straight out of `odin doc`, before filtering
Raw_Sym :: struct {
	sig:  string,
	file: string,
	doc:  [dynamic]string,
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

is_test_file :: proc(f: string) -> bool {
	return strings.has_prefix(f, "test_") || strings.has_prefix(f, "bench_")
}

is_ident :: proc(c: u8) -> bool {
	return c == '_' || c == '$' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

leading_ident :: proc(s: string) -> string {
	i := 0
	for i < len(s) && is_ident(s[i]) {i += 1}
	return s[:i]
}

// names declared at file scope: `name :: ...` or `name := ...` at column 0
decl_names :: proc(path: string, into: ^map[string]struct{}) {
	text := read(path)
	for line in strings.split_lines_iterator(&text) {
		name := leading_ident(line)
		if len(name) == 0 || (name[0] >= '0' && name[0] <= '9') {continue}
		rest := strings.trim_left_space(line[len(name):])
		if strings.has_prefix(rest, "::") || strings.has_prefix(rest, ":=") {
			into[name] = {}
		}
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
			// trailing "/* pkg:file.odin!offset */"
			if strings.has_suffix(body, " */") {
				if i := strings.last_index(body, "/* "); i >= 0 {
					loc := body[i + 3:len(body) - 3]
					if c := strings.index_byte(loc, ':'); c >= 0 {
						if b := strings.index_byte(loc, '!'); b > c {
							s.file = loc[c + 1:b]
							s.sig = strings.trim_right_space(body[:i])
						}
					}
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

load_pkg :: proc(path: string) -> Pkg {
	infos, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {die("cannot list %s: %v", path, err)}

	// names declared only in test/bench files are hidden from the reference
	test_names, real_names: map[string]struct{}
	for fi in infos {
		if !strings.has_suffix(fi.name, ".odin") {continue}
		decl_names(fi.fullpath, is_test_file(fi.name) ? &test_names : &real_names)
	}
	for n in real_names {delete_key(&test_names, n)}

	doc, raw := parse_doc(run("odin", "doc", path))
	sections: [dynamic]Section
	for r in raw {
		syms: [dynamic]Sym
		for s in r.syms {
			if is_test_file(s.file) || leading_ident(s.sig) in test_names {continue}
			append(&syms, Sym{sig = s.sig, doc = strings.join(s.doc[:], "\n")})
		}
		if len(syms) > 0 {append(&sections, Section{name = r.name, syms = syms[:]})}
	}
	return {path = path, doc = strings.join(doc[:], "\n"), sections = sections[:]}
}

load_examples :: proc() -> []Example {
	infos, err := os.read_all_directory_by_path("examples", context.allocator)
	if err != nil {die("cannot list examples: %v", err)}
	out: [dynamic]Example
	for fi in infos {
		main_path, _ := filepath.join({"examples", fi.name, "main.odin"})
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
		append(&out, Example{
			name = fi.name,
			desc = strings.join(desc[:], " "),
			source = source,
			video = os.exists(video_path),
		})
	}
	// cube first, as the hello world; the rest alphabetical
	slice.sort_by(out[:], proc(a, b: Example) -> bool {
		if (a.name == "cube") != (b.name == "cube") {return a.name == "cube"}
		return a.name < b.name
	})
	return out[:]
}

emit :: proc(path, global: string, value: any) {
	data, err := json.marshal(value, {}, context.allocator)
	if err != nil {die("cannot encode %s: %v", global, err)}
	write(path, fmt.aprintf("window.%s = %s;\n", global, string(data)))
}

main :: proc() {
	if len(os.args) != 2 {die("usage: gen <output dir>")}
	out := os.args[1]
	if err := os.make_directory_all(out); err != nil && err != os.General_Error.Exist {
		die("cannot create %s: %v", out, err)
	}

	pkgs: [dynamic]Pkg
	for d in package_dirs() {append(&pkgs, load_pkg(d))}
	emit(strings.concatenate({out, "/api.js"}), "API", pkgs[:])
	examples := load_examples()
	emit(strings.concatenate({out, "/examples.js"}), "EXAMPLES", examples)
	fmt.printfln("wrote %d packages, %d examples to %s", len(pkgs), len(examples), out)
}
