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
	timeout 50s odin test test/detour -out:bin/test && \
	timeout 50s odin test test/detour_crowd -out:bin/test

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
