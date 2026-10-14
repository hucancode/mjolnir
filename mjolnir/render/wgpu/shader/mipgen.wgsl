// Renders a mip level from the one above: a fullscreen triangle sampling it bilinearly.

@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var source_sampler: sampler;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> VertexOut {
    let uv = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    var out: VertexOut;
    out.clip = vec4f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return textureSampleLevel(source, source_sampler, in.uv, 0.0);
}
