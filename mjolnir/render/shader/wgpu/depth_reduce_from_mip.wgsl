// depth_reduce.wgsl's source past mip 0: the mip above.
@group(3) @binding(0) var source: texture_2d<f32>;

fn source_texel(p: vec2i) -> f32 {
    return textureLoad(source, p, 0).r;
}
