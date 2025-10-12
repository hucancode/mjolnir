SHADER_DIR := mjolnir/shader

# Find all shader files
VERT_SHADERS := $(shell find $(SHADER_DIR) -name "shader.vert")
FRAG_SHADERS := $(shell find $(SHADER_DIR) -name "shader.frag")
SPV_SHADERS := $(patsubst $(SHADER_DIR)/%/shader.vert,$(SHADER_DIR)/%/vert.spv,$(VERT_SHADERS)) \
               $(patsubst $(SHADER_DIR)/%/shader.frag,$(SHADER_DIR)/%/frag.spv,$(FRAG_SHADERS))
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

capture: build
	@# Capture settings
	@APP_PATH="./bin/main"; \
	FRAME_N="5"; \
	OUT_DIR="."; \
	PPM_FILE="$$OUT_DIR/$$FRAME_N.ppm"; \
	PNG_FILE="$$OUT_DIR/screenshot.png"; \
	TIMEOUT_SEC="6"; \
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
	if [ -f "$$PPM_FILE" ]; then \
		convert "$$PPM_FILE" "$$PNG_FILE"; \
		rm -f "$$PPM_FILE"; \
		echo "Screenshot saved: $$PNG_FILE"; \
	else \
		echo "Error: no screenshot captured (file not found: $$PPM_FILE)" >&2; \
		exit 1; \
	fi

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

.PHONY: build run debug shader test check clean
