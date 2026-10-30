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

# The sandbox example exercises most features at once: the general test.
SANDBOX := examples/creative/sandbox

run: shader
	odin run $(SANDBOX) -out:bin/main

debug: shader
	VK_LOADER_DEBUG=all VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation odin run $(SANDBOX) -out:bin/main-debug -debug

build: shader
	odin build $(SANDBOX) -out:bin/main

build-debug: shader
	odin build $(SANDBOX) -out:bin/main-debug -debug

shader: $(SPV_SHADERS) $(WGSL_SHADERS)
	@echo "Shader compilation complete."

# The WebGPU backend. Natively it needs wgpu-native in Odin's vendor/wgpu/lib (see
# vendor/wgpu/doc.odin).
run-wgpu: shader
	odin run $(SANDBOX) -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

build-wgpu: shader
	odin build $(SANDBOX) -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

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
	odin run docs/gen -- -src=mjolnir -out=$(WEB_OUT) -examples=examples -media=docs/site -no-media=modules \
		-name=Mjolnir -url=https://github.com/hucancode/mjolnir

# The site's media, kept out of git: $(MEDIA_DIR)/videos/<example>.mp4 and
# $(MEDIA_DIR)/posters/<example>.jpg. Each example runs on the wgpu backend for MEDIA_FRAMES
# frames with FRAME_DUMP (frames read back from the backbuffer, no window capture), encoded with
# ffmpeg. An example is skipped while the hash of its sources, the engine and the assets matches
# the one of its last recording. EXAMPLE picks some; unset, every one but the modules examples.
MEDIA_FRAMES ?= 300
MEDIA_FPS ?= 30
MEDIA_DIR ?= docs/site
MEDIA_WORK := artifacts/media
MEDIA_EXAMPLES = $(or $(EXAMPLE),$(notdir $(patsubst %/main.odin,%,$(filter-out examples/modules/%,$(wildcard examples/*/*/main.odin)))))
media_hash = { git ls-files -s $(1); git diff -- $(1); } | cksum

media: shader
	@command -v ffmpeg > /dev/null || { echo "media needs ffmpeg"; exit 1; }
	@mkdir -p $(MEDIA_DIR)/videos $(MEDIA_DIR)/posters $(MEDIA_WORK) bin
	@engine=$$($(call media_hash,mjolnir assets)); failed=; \
	for name in $(MEDIA_EXAMPLES); do \
		dir=$$(ls -d examples/*/$$name); work=$(MEDIA_WORK)/$$name; \
		video=$(MEDIA_DIR)/videos/$$name.mp4; poster=$(MEDIA_DIR)/posters/$$name.jpg; \
		sum="$$engine $(MEDIA_FRAMES) $(MEDIA_FPS) $$($(call media_hash,$$dir))"; \
		if [ -f $$video ] && [ -f $$poster ] && [ "$$(cat $$work.sum 2>/dev/null)" = "$$sum" ]; then \
			echo "== $$name (up to date)"; continue; \
		fi; \
		echo "== $$name"; \
		rm -rf $$work $$work.sum; \
		if odin build $$dir -out:bin/media_$$name -define:RENDER_BACKEND=wgpu \
			-define:RENDER_FPS=$(MEDIA_FPS) -define:FRAME_LIMIT=$(MEDIA_FRAMES) -define:FRAME_DUMP=$$work \
			> $$work.log 2>&1; then \
			./bin/media_$$name >> $$work.log 2>&1; \
			ffmpeg -nostdin -y -loglevel error -framerate $(MEDIA_FPS) -i $$work/%05d.png \
				-vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p \
				-movflags +faststart $$video >> $$work.log 2>&1 && \
			ffmpeg -nostdin -y -loglevel error -i $$work/$$(printf %05d $$(($(MEDIA_FRAMES) * 2 / 5))).png \
				-vf scale=480:-2 -q:v 4 $$poster >> $$work.log 2>&1 && \
			echo "$$sum" > $$work.sum; \
		else false; fi || { echo "   failed, see $$work.log"; tail -n 15 $$work.log | sed 's/^/   | /'; failed="$$failed $$name"; }; \
		rm -rf $$work; \
	done; \
	if [ -n "$$failed" ]; then echo "media failed:$$failed"; exit 1; fi

# Runs every modules example natively (windowed ones for MODULE_FRAMES frames), writing
# artifacts/modules/, after checking each imports no root package and Layer 2+ packages of one
# module only. Each splits into main.odin, shared, and a native.odin and web.odin driver.
MODULE_FRAMES ?= 120
modules: shader
	@for d in examples/modules/*/; do \
		name=$$(basename $$d); \
		imports=$$(grep -h '^import' $$d*.odin | grep -o '"mjolnir[^"]*"' | tr -d '"' | sort -u); \
		if echo "$$imports" | grep -qx mjolnir; then echo "$$name imports the root package"; exit 1; fi; \
		families=$$(for i in $$imports; do grep -q "^// Layer [23]" $$i/doc.odin 2>/dev/null && echo $$i | cut -d/ -f2; done | sort -u); \
		if [ $$(echo "$$families" | grep -c .) -gt 1 ]; then echo "$$name uses more than one module: $$families"; exit 1; fi; \
		echo "== $$name"; \
		odin run $$d -out:bin/$$name -define:FRAMES=$(MODULE_FRAMES) || exit 1; \
	done

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

.PHONY: run debug build build-debug shader run-wgpu build-wgpu example example-wgpu web doc record modules clean long-proc long-file long-example compare-physics
