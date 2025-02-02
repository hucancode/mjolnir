release: main.odin shader
	odin run . -out:bin/hello-vk
debug: main.odin shader
	odin run . -out:bin/hello-vk -debug
shader:
	glslc shaders/shader.vert -o shaders/vert.spv
	glslc shaders/shader.frag -o shaders/frag.spv
