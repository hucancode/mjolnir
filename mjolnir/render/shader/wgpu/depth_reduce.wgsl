// One level of a max-depth pyramid: each texel holds the farthest depth of the 2x2 source
// texels below it (source: the depth image for mip 0, read as unfilterable float, half its
// size, the mip above otherwise). Clamping repeats the last row and column of an odd-sized
// source.

@group(3) @binding(0) var source: texture_2d<f32>;
@group(3) @binding(1) var destination: texture_storage_2d<r32float, write>;

fn source_texel(p: vec2i) -> f32 {
    return textureLoad(source, p, 0).r;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    let size = textureDimensions(destination);
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    let last = vec2i(textureDimensions(source)) - 1;
    let p = vec2i(gid.xy) * 2;
    let lo = min(p, last);
    let hi = min(p + 1, last);
    let value = max(
        max(source_texel(lo), source_texel(vec2i(hi.x, lo.y))),
        max(source_texel(vec2i(lo.x, hi.y)), source_texel(hi)),
    );
    textureStore(destination, vec2i(gid.xy), vec4f(value));
}
