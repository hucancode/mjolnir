// The vertex shader and bindings of every post-process effect (texture group POST). An effect
// file follows with its fs_main and its Effect struct: the active PostprocessEffect variant's
// fields, at offset 32 of the uniforms.

@group(1) @binding(0) var input_texture: texture_2d<f32>;
// the previous pass's input (bloom V composites over the scene as it entered bloom H)
@group(1) @binding(1) var original_texture: texture_2d<f32>;
@group(1) @binding(2) var normal_texture: texture_2d<f32>;
@group(1) @binding(3) var depth_texture: texture_depth_2d;

struct PostPush {
    // camera clip planes, for effects that linearize depth (fog, dof, outline)
    camera_near: f32,
    camera_far: f32,
    // texture handles; a bindless shader indexes with them, here they are bound as a group
    normal_texture: u32,
    depth_texture: u32,
    input_image: u32,
    original_image: u32,
    // this pass of the effect
    pass_index: u32,
    _pad0: u32,
    effect: Effect,
}
@group(2) @binding(0) var<uniform> u: PostPush;

// View depth from the depth image, between the camera's clip planes.
fn linearize_depth(depth: f32) -> f32 {
    return u.camera_near * u.camera_far / (u.camera_far - depth * (u.camera_far - u.camera_near));
}

fn gaussian_weight(distance: f32, sigma: f32) -> f32 {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) uv: vec2f,
}

// A triangle covering the screen; uv follows framebuffer coordinates (0 at the top left).
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> VertexOut {
    var positions = array(vec2f(-1.0, 3.0), vec2f(3.0, -1.0), vec2f(-1.0, -1.0));
    var uvs = array(vec2f(0.0, 2.0), vec2f(2.0, 0.0), vec2f(0.0, 0.0));
    var out: VertexOut;
    out.clip = clip_output(vec4f(positions[i], 0.0, 1.0));
    out.uv = uvs[i];
    return out;
}

// Depth of the texel at uv (depth textures do not filter).
fn depth_at(uv: vec2f) -> f32 {
    let size = vec2i(textureDimensions(depth_texture));
    return textureLoad(depth_texture, clamp(vec2i(uv * vec2f(size)), vec2i(0), size - 1), 0);
}
