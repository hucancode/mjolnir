// depth_reduce.wgsl's source for mip 0: the depth image.
@group(3) @binding(0) var source: texture_depth_2d;

fn source_texel(p: vec2i) -> f32 {
    return textureLoad(source, p, 0);
}
