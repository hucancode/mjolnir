SHADER_DIR := mjolnir/shader

# Find all shader files
VERT_SHADERS := $(shell find $(SHADER_DIR) -name "shader.vert")
FRAG_SHADERS := $(shell find $(SHADER_DIR) -name "shader.frag")
SPV_SHADERS := $(patsubst $(SHADER_DIR)/%/shader.vert,$(SHADER_DIR)/%/vert.spv,$(VERT_SHADERS)) \
               $(patsubst $(SHADER_DIR)/%/shader.frag,$(SHADER_DIR)/%/frag.spv,$(FRAG_SHADERS))
COMP_SHADERS := $(shell find $(SHADER_DIR) -name "compute.comp")
SPV_COMPUTE_SHADERS := $(patsubst $(SHADER_DIR)/%/compute.comp,$(SHADER_DIR)/%/compute.spv,$(COMP_SHADERS))

release: $(SPV_SHADERS) $(SPV_COMPUTE_SHADERS)
	odin run . -out:bin/main

debug: $(SPV_SHADERS) $(SPV_COMPUTE_SHADERS)
	odin run . -out:bin/main -debug

test:
	odin test test -out:bin/test

clean:
	rm -rf bin

$(SHADER_DIR)/%/compute.spv: $(SHADER_DIR)/%/compute.comp
	@echo "Compiling compute shader $<..."
	@glslc "$<" -o "$@"

$(SHADER_DIR)/%/vert.spv: $(SHADER_DIR)/%/shader.vert
	@echo "Compiling vertex shader $<..."
	@glslc "$<" -o "$@"

$(SHADER_DIR)/%/frag.spv: $(SHADER_DIR)/%/shader.frag
	@echo "Compiling fragment shader $<..."
	@glslc "$<" -o "$@"

.PHONY: release debug test clean
