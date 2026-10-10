package ui_commands

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

DrawTextCommand :: struct {
	position:       [2]f32,
	glyphs:         []DrawTextGlyph,
	font_atlas_id:  u32,
	z_order:        i32,
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
