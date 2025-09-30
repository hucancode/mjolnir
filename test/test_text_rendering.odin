package tests

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"
import fs "vendor:fontstash"
import "../mjolnir/render/text"

@(test)
test_fontstash_init :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  font_ctx: fs.FontContext
  fs.Init(&font_ctx, 512, 512, .TOPLEFT)
  defer fs.Destroy(&font_ctx)
  testing.expect(
    t,
    font_ctx.width == 512,
    "Font context width should be 512",
  )
  testing.expect(
    t,
    font_ctx.height == 512,
    "Font context height should be 512",
  )
  testing.expect(
    t,
    len(font_ctx.textureData) == 512 * 512,
    "Font context texture data should have correct size",
  )
}

@(test)
test_text_vertex_structure :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  vertex := text.Vertex {
    pos   = {100, 200},
    uv    = {0.5, 0.5},
    color = {255, 255, 255, 255},
  }
  testing.expect(
    t,
    vertex.pos.x == 100,
    "Vertex position x should be 100",
  )
  testing.expect(
    t,
    vertex.pos.y == 200,
    "Vertex position y should be 200",
  )
  testing.expect(
    t,
    vertex.uv.x == 0.5,
    "Vertex UV x should be 0.5",
  )
  testing.expect(
    t,
    vertex.uv.y == 0.5,
    "Vertex UV y should be 0.5",
  )
  testing.expect(
    t,
    vertex.color.r == 255,
    "Vertex color red should be 255",
  )
}

@(test)
test_text_renderer_constants :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  testing.expect(
    t,
    text.TEXT_MAX_QUADS == 4096,
    "TEXT_MAX_QUADS should be 4096",
  )
  testing.expect(
    t,
    text.TEXT_MAX_VERTICES == text.TEXT_MAX_QUADS * 4,
    "TEXT_MAX_VERTICES should be TEXT_MAX_QUADS * 4",
  )
  testing.expect(
    t,
    text.TEXT_MAX_INDICES == text.TEXT_MAX_QUADS * 6,
    "TEXT_MAX_INDICES should be TEXT_MAX_QUADS * 6",
  )
  testing.expect(
    t,
    text.ATLAS_WIDTH == 1024,
    "ATLAS_WIDTH should be 1024",
  )
  testing.expect(
    t,
    text.ATLAS_HEIGHT == 1024,
    "ATLAS_HEIGHT should be 1024",
  )
}

@(test)
test_fontstash_state_management :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  font_ctx: fs.FontContext
  fs.Init(&font_ctx, 256, 256, .TOPLEFT)
  defer fs.Destroy(&font_ctx)
  initial_state_count := font_ctx.state_count
  testing.expect(
    t,
    initial_state_count == 1,
    "Initial state count should be 1",
  )
  fs.PushState(&font_ctx)
  testing.expect(
    t,
    font_ctx.state_count == 2,
    "After push, state count should be 2",
  )
  fs.SetSize(&font_ctx, 24.0)
  fs.PopState(&font_ctx)
  testing.expect(
    t,
    font_ctx.state_count == 1,
    "After pop, state count should be 1",
  )
}

@(test)
test_fontstash_dirty_rect :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  font_ctx: fs.FontContext
  fs.Init(&font_ctx, 256, 256, .TOPLEFT)
  defer fs.Destroy(&font_ctx)
  dirty: [4]f32
  has_dirty := fs.ValidateTexture(&font_ctx, &dirty)
  testing.expect(
    t,
    has_dirty == true,
    "After init, texture should be dirty",
  )
  testing.expect(
    t,
    dirty[0] >= 0 && dirty[1] >= 0,
    "Dirty rect min coordinates should be valid",
  )
  testing.expect(
    t,
    dirty[2] <= f32(font_ctx.width) && dirty[3] <= f32(font_ctx.height),
    "Dirty rect max coordinates should be within atlas bounds",
  )
  has_dirty_2 := fs.ValidateTexture(&font_ctx, &dirty)
  testing.expect(
    t,
    has_dirty_2 == false,
    "After validation, texture should not be dirty",
  )
}

@(test)
test_text_quad_layout :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  quad := fs.Quad {
    x0 = 10,
    y0 = 20,
    s0 = 0.1,
    t0 = 0.2,
    x1 = 30,
    y1 = 40,
    s1 = 0.3,
    t1 = 0.4,
  }
  width := quad.x1 - quad.x0
  height := quad.y1 - quad.y0
  testing.expect(t, width == 20, "Quad width should be 20")
  testing.expect(t, height == 20, "Quad height should be 20")
  testing.expect(
    t,
    quad.s0 < quad.s1,
    "UV coordinates should be properly ordered",
  )
  testing.expect(
    t,
    quad.t0 < quad.t1,
    "UV coordinates should be properly ordered",
  )
}