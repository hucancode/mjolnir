SHADER_DIR := mjolnir/shader

# Find all shader files
VERT_SHADERS := $(shell find $(SHADER_DIR) -name "shader.vert")
FRAG_SHADERS := $(shell find $(SHADER_DIR) -name "shader.frag")
GEOM_SHADERS := $(shell find $(SHADER_DIR) -name "shader.geom")
SPV_SHADERS := $(patsubst $(SHADER_DIR)/%/shader.vert,$(SHADER_DIR)/%/vert.spv,$(VERT_SHADERS)) \
               $(patsubst $(SHADER_DIR)/%/shader.frag,$(SHADER_DIR)/%/frag.spv,$(FRAG_SHADERS)) \
               $(patsubst $(SHADER_DIR)/%/shader.geom,$(SHADER_DIR)/%/geom.spv,$(GEOM_SHADERS))
COMP_SHADERS := $(shell find $(SHADER_DIR) -name "*.comp")
SPV_COMPUTE_SHADERS := $(patsubst %.comp,%.spv,$(COMP_SHADERS))

run: shader
	odin run . -out:bin/main

debug: shader
	VK_LOADER_DEBUG=all VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation odin run . -out:bin/main-debug -debug

build: shader
	odin build . -out:bin/main

build-debug: shader
	odin build . -out:bin/main-debug -debug

check: shader
	odin check .

shader: $(SPV_SHADERS) $(SPV_COMPUTE_SHADERS)
	@echo "Shader compilation complete."

test:
	timeout 120s odin test . --all-packages

VISUAL_TESTS := cube blend_ik_cesium_man blend_ik_fox gltf_animation gltf_skinning gltf_static grid256 grid300 grid5 light material navmesh shadow aoe crosshatch ui spline

vtest:
	@echo "Running all samples..."
	@mkdir -p artifacts
	@failed=0; \
	for test_name in $(VISUAL_TESTS); do \
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
	@for test_name in $(VISUAL_TESTS); do \
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

$(SHADER_DIR)/%/geom.spv: $(SHADER_DIR)/%/shader.geom
	@echo "Compiling geometry shader $<..."
	@glslc "$<" -o "$@"

long-proc:
	grep -rhE "^\s*[a-zA-Z0-9_]+\s*::\s*proc" mjolnir --include \*.odin | \
      awk '{for(i=1; i<=NF; i++) {if($$i == "::") {print $$(i-1); break}}}' | \
      awk '{print length, $$0}' | \
      sort -rn | \
      head -n20

long-file:
	find mjolnir -type f -name "*.odin" -exec wc -l {} + | sort -rn | head -n20

.PHONY: build run debug shader test check clean vtest golden long-proc long-file
