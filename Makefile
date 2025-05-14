SHADER_DIR := mjolnir/shader

release: main.odin shaders
	odin run . -out:bin/main

debug: main.odin shaders
	odin run . -out:bin/main -debug

shaders:
	@for dir in $(shell find $(SHADER_DIR) -type d); do \
		if [ -f "$$dir/shader.vert" ]; then \
			echo "Compiling vertex shader in $$dir..."; \
			glslc "$$dir/shader.vert" -o "$$dir/vert.spv"; \
		fi; \
		if [ -f "$$dir/shader.frag" ]; then \
			echo "Compiling fragment shader in $$dir..."; \
			glslc "$$dir/shader.frag" -o "$$dir/frag.spv"; \
		fi; \
	done
