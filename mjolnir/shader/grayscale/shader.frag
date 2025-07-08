#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

layout(set = 0, binding = 0) uniform GBufferIndices {
    uint gbuffer_position_index;
    uint gbuffer_normal_index;
    uint gbuffer_albedo_index;
    uint gbuffer_metallic_index;
    uint gbuffer_emissive_index;
    uint input_image_index;
    uint padding[2];
} gbuffer_indices;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube textures_cube[];

layout(push_constant) uniform GrayscaleParams {
    vec3 weights;
    float strength;
};

void main() {
    vec4 color = texture(sampler2D(textures[gbuffer_indices.input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    float gray = dot(color.rgb, weights);
    out_color = mix(color, vec4(gray, gray, gray, color.a), strength);
}
