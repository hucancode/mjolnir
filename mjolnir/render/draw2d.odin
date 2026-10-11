// 2D draw commands: the data contract between a 2D producer (ui) and a 2D
// renderer (render/ui). Plain data, no dependencies.
package render

// texture_id value meaning "untextured"; the renderer substitutes a white texture.
NO_TEXTURE :: max(u32)

DrawQuadCommand :: struct {
	position:   [2]f32,
	size:       [2]f32,
	color:      [4]u8,
	texture_id: u32,
	z_order:    i32,
}

DrawTextGlyph :: struct {
	p0:    [2]f32,
	p1:    [2]f32,
	uv0:   [2]f32,
	uv1:   [2]f32,
	color: [4]u8,
}

// Glyph uvs index the producer's font atlas, which the renderer owns on the GPU.
DrawTextCommand :: struct {
	position: [2]f32,
	glyphs:   []DrawTextGlyph,
	z_order:  i32,
}

Vertex2D :: struct {
	pos:        [2]f32,
	uv:         [2]f32,
	color:      [4]u8,
	texture_id: u32,
}

DrawMeshCommand :: struct {
	position:   [2]f32,
	vertices:   []Vertex2D,
	indices:    []u32,
	texture_id: u32,
	z_order:    i32,
}

RenderCommand :: union {
	DrawQuadCommand,
	DrawTextCommand,
	DrawMeshCommand,
}

// One frame of 2D output. `atlas` holds the producer's R8 font atlas
// (`atlas_size` texels) only on frames where it changed; otherwise it is empty.
DrawList :: struct {
	commands:   []RenderCommand,
	atlas:      []u8,
	atlas_size: [2]u32,
}
