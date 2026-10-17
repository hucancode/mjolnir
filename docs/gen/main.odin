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

// render's GPU layer: no application imports these, so the reference leaves them out
INTERNAL := [?]string{"mjolnir/render/rhi", "mjolnir/render/vulkan", "mjolnir/render/wgpu"}

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
		if d not_in seen && !slice.contains(INTERNAL[:], d) {
			seen[d] = {}
			append(&dirs, d)
		}
	}
	slice.sort(dirs[:])
	return dirs[:]
}

// definitions in the left-out GPU layer, by qualified name ("rhi.BlendMode" -> "enum {...}")
internal_defs :: proc() -> map[string]string {
	defs: map[string]string
	for path in INTERNAL {
		_, raw := parse_doc(run("odin", "doc", path))
		pkg := filepath.base(path)
		for r in raw {
			for s in r.syms {
				if i := strings.index(s.sig, " :: "); i >= 0 {
					defs[strings.concatenate({pkg, ".", s.sig[:i]})] = s.sig[i + 4:]
				}
			}
		}
	}
	return defs
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

// `defs` resolves aliases of the GPU layer (render's `BlendMode :: rhi.BlendMode`), which the
// reference leaves out, to their definitions
load_pkg :: proc(path: string, defs: map[string]string) -> Pkg {
	// test files are #+private, so `odin doc` leaves their symbols out
	doc, raw := parse_doc(run("odin", "doc", path))
	sections: [dynamic]Section
	for r in raw {
		syms: [dynamic]Sym
		for s in r.syms {
			sig := s.sig
			if i := strings.index(sig, " :: "); i >= 0 {
				if def, ok := defs[sig[i + 4:]]; ok {sig = strings.concatenate({sig[:i + 4], def})}
			}
			sig = drop_private_using(sig)
			append(&syms, Sym{sig = sig, doc = strings.join(s.doc[:], "\n")})
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
		wasm_path, _ := filepath.join({"docs", "build", "live", fmt.tprintf("%s.wasm", fi.name)})
		append(&out, Example{
			name = fi.name,
			desc = strings.join(desc[:], " "),
			source = source,
			video = os.exists(video_path),
			wasm = os.exists(wasm_path),
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
	defs := internal_defs()
	for d in package_dirs() {append(&pkgs, load_pkg(d, defs))}
	emit(strings.concatenate({out, "/api.js"}), "API", pkgs[:])
	examples := load_examples()
	emit(strings.concatenate({out, "/examples.js"}), "EXAMPLES", examples)
	fmt.printfln("wrote %d packages, %d examples to %s", len(pkgs), len(examples), out)
}
