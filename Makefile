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
	odin run . -out:bin/main-debug -debug

build: shader
	odin build . -out:bin/main

build-debug: shader
	odin build . -out:bin/main -debug

check: shader
	odin check .

shader: $(SPV_SHADERS) $(SPV_COMPUTE_SHADERS)
	@echo "Shader compilation complete."

test:
	timeout 50s odin test test -out:bin/test && \
	timeout 50s odin test test/recast -out:bin/test && \
	timeout 50s odin test test/detour -out:bin/test

VISUAL_TESTS := cube gltf_animation gltf_skinning gltf_static grid256 grid300 grid5 light material navmesh shadow

vtest:
	@echo "Running all visual tests..."
	@mkdir -p artifacts
	@failed=0; \
	for test_name in $(VISUAL_TESTS); do \
		echo "Testing $$test_name..."; \
		./test/visual/run.py "$$test_name" artifacts || failed=$$((failed + 1)); \
	done; \
	if [ $$failed -ne 0 ]; then \
		echo "$$failed visual test(s) failed" >&2; \
		exit 1; \
	fi; \
	echo "All visual tests passed."

golden:
	@echo "Regenerating all visual test golden images..."
	@mkdir -p artifacts
	@for test_name in $(VISUAL_TESTS); do \
		echo "Updating golden image for $$test_name..."; \
		UPDATE_GOLDEN=1 ./test/visual/run.py "$$test_name" artifacts || exit 1; \
	done
	@echo "All golden images updated successfully."

capture: build
	@# Capture settings
	@APP_PATH="./bin/main"; \
	FRAME_N="5,6"; \
	OUT_DIR="screenshots"; \
	PPM_FILE="$$OUT_DIR/$$FRAME_N.ppm"; \
	PNG_FILE="$$OUT_DIR/screenshot.png"; \
	TIMEOUT_SEC="10"; \
	\
	command -v convert >/dev/null || { echo "Error: ImageMagick 'convert' not found" >&2; exit 1; }; \
	command -v xvfb-run >/dev/null || { echo "Error: 'xvfb-run' not found" >&2; exit 1; }; \
	\
	echo "Running $$APP_PATH for $$TIMEOUT_SEC seconds to capture frame $$FRAME_N..."; \
	VK_INSTANCE_LAYERS="VK_LAYER_LUNARG_screenshot" \
	VK_SCREENSHOT_FRAMES="$$FRAME_N" \
	VK_SCREENSHOT_DIR="$$OUT_DIR" \
	xvfb-run -a -s "-screen 0 1920x1080x24" \
	timeout "$${TIMEOUT_SEC}s" "$$APP_PATH" || true; \
	\
	for f in "$$OUT_DIR/"*.ppm; do \
		out="$${f%.ppm}.png"; \
		echo "Converting $$f -> $$out"; \
		convert "$$f" "$$out"; \
	done
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

.PHONY: build run debug shader test check clean vtest golden
