SHADER_DIR := mjolnir/render/shader

# One Slang source per shader (engine: $(SHADER_DIR)/*.slang, users: examples/*/*/*.slang), compiled
# for the backend: name.spv (Vulkan) or name.wgsl (wgpu). Shaders branch on BACKEND_VULKAN and
# BACKEND_WGPU where the backends differ. The headers are only included.
SHADER_HEADERS := common mesh mesh_vertex mesh_pulled material post gpu ibl_common
SLANG_SOURCES := $(filter-out $(addprefix $(SHADER_DIR)/,$(addsuffix .slang,$(SHADER_HEADERS))) examples/creative/snake/snake_skin.slang,$(wildcard $(SHADER_DIR)/*.slang) $(wildcard examples/*/*/*.slang))
SLANG_ENTRIES := $(shell grep -l '\[shader' $(SLANG_SOURCES) 2>/dev/null)
SLANG_HEADERS := $(wildcard $(SHADER_DIR)/*.slang examples/*/*/*.slang)
SLANG_FLAGS := -I $(SHADER_DIR) -matrix-layout-column-major -warnings-disable 39001
SPV_SHADERS := $(SLANG_ENTRIES:.slang=.spv)
WGSL_SHADERS := $(SLANG_ENTRIES:.slang=.wgsl)

run: shader
	odin run . -out:bin/main

debug: shader
	VK_LOADER_DEBUG=all VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation odin run . -out:bin/main-debug -debug

build: shader
	odin build . -out:bin/main

build-debug: shader
	odin build . -out:bin/main-debug -debug

shader: $(SPV_SHADERS) $(WGSL_SHADERS)
	@echo "Shader compilation complete."

# The WebGPU backend. Natively it needs wgpu-native in Odin's vendor/wgpu/lib (see
# vendor/wgpu/doc.odin).
run-wgpu: shader
	odin run . -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

build-wgpu: shader
	odin build . -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

# Examples live in examples/<category>/<name>; everything else addresses them by bare name.
# EXAMPLE picks one (cube when unset); record takes all of them when unset.
example_dir = $(firstword $(wildcard examples/*/$(1)))
EXAMPLES := $(notdir $(patsubst %/main.odin,%,$(wildcard examples/*/*/main.odin)))
ONE_EXAMPLE = $(or $(EXAMPLE),cube)

example: shader
	odin run $(call example_dir,$(ONE_EXAMPLE)) -out:bin/$(ONE_EXAMPLE)

example-wgpu: shader
	odin run $(call example_dir,$(ONE_EXAMPLE)) -out:bin/$(ONE_EXAMPLE)-wgpu -define:RENDER_BACKEND=wgpu

# Web builds go to WEB_OUT: <example>.wasm beside Odin's JS runtime, the WebGPU glue and the host
# page (mjolnir/platform/web/index.html).
# Linking needs wasm-ld (LLVM's lld) on PATH.
ODIN_ROOT := $(shell odin root)
WEB_OUT := docs/build/data
WASM_FLAGS := -target:js_wasm32 -define:RENDER_BACKEND=wgpu -target-features:"atomics,bulk-memory" \
	-no-thread-local -extra-linker-flags:"--export-table"
define web_runtime
	mkdir -p $(WEB_OUT)
	cp $(ODIN_ROOT)core/sys/wasm/js/odin.js $(ODIN_ROOT)vendor/wgpu/wgpu.js mjolnir/platform/web/index.html $(WEB_OUT)/
endef

# Serve docs/build and open data/index.html?example=$(EXAMPLE).
web: shader
	$(web_runtime)
	odin build $(call example_dir,$(ONE_EXAMPLE)) $(WASM_FLAGS) -out:$(WEB_OUT)/$(ONE_EXAMPLE).wasm

# The site: docs/site, every example that builds for the web (the rest fall back to their
# video), and the API and examples data.
doc: shader
	rm -rf docs/build
	mkdir -p docs/build
	cp -R docs/site/. docs/build/
	$(web_runtime)
	@for name in $(EXAMPLES); do \
		echo "wasm: $$name"; \
		odin build $$(ls -d examples/*/$$name) $(WASM_FLAGS) -out:$(WEB_OUT)/$$name.wasm >/dev/null 2>&1 \
			|| echo "  skipped $$name (no web build)"; \
	done
	odin run docs/gen -- -src=mjolnir -out=$(WEB_OUT) -examples=examples -media=docs/site \
		-name=Mjolnir -url=https://github.com/hucancode/mjolnir

# docs/site/videos/<example>.mp4 and docs/site/posters/<example>.jpg (see examples/record.sh).
record: shader
	./examples/record.sh $(RECORD_ARGS) $(EXAMPLE)

clean:
	rm -rf bin/*

%.spv: %.slang $(SLANG_HEADERS)
	@echo "Compiling shader $< for Vulkan..."
	@slangc "$<" $(SLANG_FLAGS) -target spirv -fvk-use-entrypoint-name -D BACKEND_VULKAN=1 -D BACKEND_WGPU=0 -o "$@"

%.wgsl: %.slang $(SLANG_HEADERS)
	@echo "Compiling shader $< for wgpu..."
	@slangc "$<" $(SLANG_FLAGS) -target wgsl -D BACKEND_VULKAN=0 -D BACKEND_WGPU=1 -o "$@"

long-proc:
	grep -rhE "^\s*[a-zA-Z0-9_]+\s*::\s*proc" mjolnir --include \*.odin | \
      awk '{for(i=1; i<=NF; i++) {if($$i == "::") {print $$(i-1); break}}}' | \
      awk '{print length, $$0}' | \
      sort -rn | \
      head -n20

long-file:
	find mjolnir -type f -name "*.odin" -exec wc -l {} + | sort -rn | head -n20

long-example:
	find examples -type f -name "main.odin" -exec wc -l {} + | sort -rn | head -n20

compare-physics:
	git stash -u
	odin build examples/basic/physics -out:bin/physics_before -disable-assert -no-bounds-check -o:speed -define:NX=30 -define:NY=30 -define:NZ=30
	git stash pop
	odin build examples/basic/physics -out:bin/physics_after -disable-assert -no-bounds-check -o:speed -define:NX=30 -define:NY=30 -define:NZ=30
	timeout 10s perf record -F 999 -g --call-graph dwarf ./bin/physics_before || true
	timeout 10s perf record -F 999 -g --call-graph dwarf ./bin/physics_after || true
	perf report -i perf.data.old --stdio --no-children -n --percent-limit 1 >perf_report_before.txt
	perf report -i perf.data --stdio --no-children -n --percent-limit 1 >perf_report_after.txt

.PHONY: run debug build build-debug shader run-wgpu build-wgpu example example-wgpu web doc record clean long-proc long-file long-example compare-physics
