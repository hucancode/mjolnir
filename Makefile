SHADER_DIR := mjolnir/render/shader

# One Slang source per shader (engine: $(SHADER_DIR)/*.slang, users: examples/*/*/*.slang), compiled
# for the backend: name.spv (Vulkan) or name.wgsl (wgpu). Shaders branch on BACKEND_VULKAN and
# BACKEND_WGPU where the backends differ. The headers are only included.
SHADER_HEADERS := common mesh mesh_vertex mesh_pulled material post gpu ibl_common
SLANG_SOURCES := $(filter-out $(addprefix $(SHADER_DIR)/,$(addsuffix .slang,$(SHADER_HEADERS))) examples/creative/cartoon_snake/snake_skin.slang,$(wildcard $(SHADER_DIR)/*.slang) $(wildcard examples/*/*/*.slang))
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

shader: $(SPV_SHADERS)
	@echo "Shader compilation complete."

shader-wgpu: $(WGSL_SHADERS)
	@echo "Shader compilation complete."

# The WebGPU backend. Natively it needs wgpu-native in Odin's vendor/wgpu/lib (see
# vendor/wgpu/doc.odin).
run-wgpu: shader-wgpu
	odin run . -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

build-wgpu: shader-wgpu
	odin build . -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

# An example on the web: web/$(EXAMPLE).wasm beside Odin's JS runtime, WebGPU glue and the
# host page (mjolnir/platform/web/index.html).
# Linking needs wasm-ld (LLVM's lld) on PATH.
ODIN_ROOT := $(shell odin root)
EXAMPLE ?= cube

web: shader-wgpu
	mkdir -p web
	odin build $(call example_dir,$(EXAMPLE)) -target:js_wasm32 -define:RENDER_BACKEND=wgpu \
		-target-features:"atomics,bulk-memory" -no-thread-local -extra-linker-flags:"--export-table" -out:web/$(EXAMPLE).wasm
	cp $(ODIN_ROOT)core/sys/wasm/js/odin.js $(ODIN_ROOT)vendor/wgpu/wgpu.js mjolnir/platform/web/index.html web/

# Examples live in examples/<category>/<name>; everything else addresses them by bare name.
example_dir = $(firstword $(wildcard examples/*/$(1)))
EXAMPLES := $(notdir $(patsubst %/main.odin,%,$(wildcard examples/*/*/main.odin)))

examples:
	@echo "Running all samples..."
	@mkdir -p artifacts
	@failed=0; \
	for test_name in $(EXAMPLES); do \
		echo "Testing $$test_name..."; \
		date; \
		./examples/run.sh "$$test_name" artifacts || failed=$$((failed + 1)); \
	done; \
	if [ $$failed -ne 0 ]; then \
		echo "$$failed example(s) malfunctioned" >&2; \
		exit 1; \
	fi; \
	echo "All examples are working normally."

golden:
	@echo "Regenerating all golden images..."
	@mkdir -p artifacts
	@for test_name in $(EXAMPLES); do \
		echo "Updating golden image for $$test_name..."; \
		UPDATE_GOLDEN=1 ./examples/run.sh "$$test_name" artifacts || exit 1; \
	done
	@echo "All golden images updated successfully."

capture: build
	@# Capture settings
	@APP_PATH="./bin/main"; \
	FRAME_N="5,6"; \
	OUT_DIR="screenshots"; \
	TIMEOUT_SEC="10"; \
	\
	command -v xvfb-run >/dev/null || { echo "Error: 'xvfb-run' not found" >&2; exit 1; }; \
	command -v magick >/dev/null || { echo "Error: 'magick' not found" >&2; exit 1; }; \
	\
	echo "Running $$APP_PATH for $$TIMEOUT_SEC seconds to capture frame $$FRAME_N..."; \
	VK_INSTANCE_LAYERS="VK_LAYER_LUNARG_screenshot" \
	VK_SCREENSHOT_FRAMES="$$FRAME_N" \
	VK_SCREENSHOT_DIR="$$OUT_DIR" \
	xvfb-run -a -s "-screen 0 1920x1080x24" \
	timeout "$${TIMEOUT_SEC}s" "$$APP_PATH" || true; \
	\
	echo "Converting PPM to PNG..."; \
	for ppm in $$OUT_DIR/*.ppm; do \
		[ -f "$$ppm" ] || continue; \
		magick "$$ppm" "$${ppm%.ppm}.png"; \
	done; \
	echo "Screenshots saved to $$OUT_DIR/"

record: shader
	@mkdir -p docs/site/videos artifacts/record
	./examples/record.sh $(EXAMPLE)

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

# Live builds for the examples page: docs/build/live/<example>.wasm plus the host page.
# Best effort: examples that do not build for the web are skipped and fall back to their video.
doc-live: shader-wgpu
	mkdir -p docs/build/live
	cp $(ODIN_ROOT)core/sys/wasm/js/odin.js $(ODIN_ROOT)vendor/wgpu/wgpu.js mjolnir/platform/web/index.html docs/build/live/
	@for name in $(EXAMPLES); do \
		echo "wasm: $$name"; \
		odin build $$(ls -d examples/*/$$name) -target:js_wasm32 -define:RENDER_BACKEND=wgpu \
			-target-features:"atomics,bulk-memory" -no-thread-local -extra-linker-flags:"--export-table" \
			-out:docs/build/live/$$name.wasm >/dev/null 2>&1 || echo "  skipped $$name (no web build)"; \
	done

doc: shader
	rm -rf docs/build
	mkdir -p docs/build
	cp -R docs/site/. docs/build/
	$(MAKE) doc-live
	odin run docs/gen -- docs/build/data

compare-physics:
	git stash -u
	odin build examples/basic/physics -out:bin/physics_before -disable-assert -no-bounds-check -o:speed -define:NX=30 -define:NY=30 -define:NZ=30
	git stash pop
	odin build examples/basic/physics -out:bin/physics_after -disable-assert -no-bounds-check -o:speed -define:NX=30 -define:NY=30 -define:NZ=30
	timeout 10s perf record -F 999 -g --call-graph dwarf ./bin/physics_before || true
	timeout 10s perf record -F 999 -g --call-graph dwarf ./bin/physics_after || true
	perf report -i perf.data.old --stdio --no-children -n --percent-limit 1 >perf_report_before.txt
	perf report -i perf.data --stdio --no-children -n --percent-limit 1 >perf_report_after.txt

.PHONY: doc-live build build-debug build-wgpu run-wgpu web run run-max debug shader shader-wgpu check clean vtest examples golden capture long-proc long-file long-example doc doc-dev record compare-physics
