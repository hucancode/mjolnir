// The 2D overlay: pixel-space vertices through an orthographic projection, one texture per
// batch (texture group SINGLE). Glyph atlases are white with coverage in alpha, so one
// multiply serves glyphs, solid quads (white texture) and images.

@group(1) @binding(0) var batch_texture: texture_2d<f32>;

struct OverlayUniforms {
    projection: mat4x4f,
}
@group(2) @binding(0) var<uniform> u: OverlayUniforms;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

@vertex
fn vs_main(@location(0) position: vec2f, @location(1) uv: vec2f, @location(2) color: vec4f) -> VertexOut {
    var out: VertexOut;
    out.clip = clip_output(u.projection * vec4f(position, 0.0, 1.0));
    out.color = color;
    out.uv = uv;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return in.color * textureSample(batch_texture, nearest_clamp, in.uv);
}
