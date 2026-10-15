SHADER_DIR := mjolnir/render/vulkan/shader

# Find all shader files
VERT_SHADERS := $(shell find $(SHADER_DIR) -name "shader.vert")
FRAG_SHADERS := $(shell find $(SHADER_DIR) -name "shader.frag")
SPV_SHADERS := $(patsubst $(SHADER_DIR)/%/shader.vert,$(SHADER_DIR)/%/vert.spv,$(VERT_SHADERS)) \
               $(patsubst $(SHADER_DIR)/%/shader.frag,$(SHADER_DIR)/%/frag.spv,$(FRAG_SHADERS))
COMP_SHADERS := $(shell find $(SHADER_DIR) -name "*.comp")
SPV_COMPUTE_SHADERS := $(patsubst %.comp,%.spv,$(COMP_SHADERS))

run: shader
	odin run . -out:bin/main

run-max: shader
	odin run . -out:bin/main -define:RENDER_FPS=200

debug: shader
	VK_LOADER_DEBUG=all VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation odin run . -out:bin/main-debug -debug

build: shader
	odin build . -out:bin/main

build-debug: shader
	odin build . -out:bin/main-debug -debug

shader: $(SPV_SHADERS) $(SPV_COMPUTE_SHADERS)
	@echo "Shader compilation complete."

# The WebGPU backend: WGSL shaders are embedded, nothing to compile ahead. Natively it needs
# wgpu-native in Odin's vendor/wgpu/lib (see vendor/wgpu/doc.odin).
run-wgpu:
	odin run . -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

build-wgpu:
	odin build . -out:bin/main-wgpu -define:RENDER_BACKEND=wgpu

# An example on the web: web/$(EXAMPLE).wasm beside Odin's JS runtime, WebGPU glue and the
# host page (mjolnir/platform/web/index.html).
# Linking needs wasm-ld (LLVM's lld) on PATH.
ODIN_ROOT := $(shell odin root)
EXAMPLE ?= cube

web:
	mkdir -p web
	odin build examples/$(EXAMPLE) -target:js_wasm32 -define:RENDER_BACKEND=wgpu \
		-target-features:"atomics,bulk-memory" -extra-linker-flags:"--export-table" -out:web/$(EXAMPLE).wasm
	cp $(ODIN_ROOT)core/sys/wasm/js/odin.js $(ODIN_ROOT)vendor/wgpu/wgpu.js mjolnir/platform/web/index.html web/

EXAMPLES := $(patsubst examples/%/main.odin,%,$(wildcard examples/*/main.odin))

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

%.spv: %.comp
	@echo "Compiling compute shader $<..."
	@glslc "$<" -o "$@"

$(SHADER_DIR)/%/vert.spv: $(SHADER_DIR)/%/shader.vert
	@echo "Compiling vertex shader $<..."
	@glslc "$<" -o "$@"

$(SHADER_DIR)/%/frag.spv: $(SHADER_DIR)/%/shader.frag
	@echo "Compiling fragment shader $<..."
	@glslc "$<" -o "$@"

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
doc-live:
	mkdir -p docs/build/live
	cp $(ODIN_ROOT)core/sys/wasm/js/odin.js $(ODIN_ROOT)vendor/wgpu/wgpu.js mjolnir/platform/web/index.html docs/build/live/
	@for name in $(EXAMPLES); do \
		echo "wasm: $$name"; \
		odin build examples/$$name -target:js_wasm32 -define:RENDER_BACKEND=wgpu \
			-target-features:"atomics,bulk-memory" -extra-linker-flags:"--export-table" \
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
	odin build examples/physics -out:bin/physics_before -disable-assert -no-bounds-check -o:speed -define:NX=30 -define:NY=30 -define:NZ=30
	git stash pop
	odin build examples/physics -out:bin/physics_after -disable-assert -no-bounds-check -o:speed -define:NX=30 -define:NY=30 -define:NZ=30
	timeout 10s perf record -F 999 -g --call-graph dwarf ./bin/physics_before || true
	timeout 10s perf record -F 999 -g --call-graph dwarf ./bin/physics_after || true
	perf report -i perf.data.old --stdio --no-children -n --percent-limit 1 >perf_report_before.txt
	perf report -i perf.data --stdio --no-children -n --percent-limit 1 >perf_report_after.txt

.PHONY: doc-live build build-debug build-wgpu run-wgpu web run run-max debug shader check clean vtest examples golden capture long-proc long-file long-example doc doc-dev record compare-physics
