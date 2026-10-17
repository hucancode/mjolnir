// The interface of a user post-process fragment shader (render.post_shader_create): the
// fullscreen uv, the color output, the bindless textures and the push block. Define
// POST_PARAMS, the fields of the shader's params as render.make_custom_effect packs them, before
// including this:
//
//     #version 450
//     #define POST_PARAMS vec3 tint; float strength;
//     #include "post.glsl"
//     void main() { out_color = post_input(v_uv) * vec4(tint, 1) * strength; }
//
// Compile with glslc -I <this directory>.

#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

// 0 at the top left
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

#ifndef POST_PARAMS
#define POST_PARAMS
#endif

layout(push_constant) uniform PostPush {
    // camera clip planes
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    // the previous pass's output
    uint input_image_index;
    // the previous pass's input
    uint original_image_index;
    // this pass of the effect, 0 .. passes - 1
    uint pass_index;
    uint _post_pad;
    // offset 32: the effect's params
    POST_PARAMS
};

vec4 sample_texture(uint index, uint sampler_index, vec2 uv) {
    return texture(sampler2D(textures[nonuniformEXT(index)], samplers[sampler_index]), uv);
}

// The previous pass's output at uv.
vec4 post_input(vec2 uv) {
    return sample_texture(input_image_index, SAMPLER_LINEAR_CLAMP, uv);
}

// The previous pass's input at uv.
vec4 post_original(vec2 uv) {
    return sample_texture(original_image_index, SAMPLER_LINEAR_CLAMP, uv);
}

// The G-buffer normal at uv, as the G-buffer stores it.
vec3 post_normal(vec2 uv) {
    return sample_texture(normal_texture_index, SAMPLER_NEAREST_CLAMP, uv).xyz;
}

// The [0, 1] depth at uv.
float post_depth(vec2 uv) {
    return sample_texture(depth_texture_index, SAMPLER_NEAREST_CLAMP, uv).r;
}

// Distance along the view axis of a depth from post_depth.
float linearize_depth(float depth) {
    return camera_near * camera_far / (camera_far - depth * (camera_far - camera_near));
}
