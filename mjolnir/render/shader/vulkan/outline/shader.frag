#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform PostProcessPushConstant {
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    vec3 outline_color;
    float thickness;
};

// Distance along the view axis from a [0, 1] perspective depth value.
float linearize_depth(float depth) {
    return camera_near * camera_far / (camera_far - depth * (camera_far - camera_near));
}

float sample_depth(vec2 uv) {
    return texture(sampler2D(textures[depth_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).r;
}

vec3 sample_normal(vec2 uv) {
    vec3 n = texture(sampler2D(textures[normal_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;
    return normalize(n * 2.0 - 1.0);
}

void main() {
    vec4 scene = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    vec2 texel = thickness / vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));

    float dc = sample_depth(v_uv);
    // Sky / background: no outline, keep scene color
    if (dc >= 1.0) {
        out_color = vec4(scene.rgb, 1.0);
        return;
    }

    float dl = sample_depth(v_uv + vec2(-texel.x, 0.0));
    float dr = sample_depth(v_uv + vec2( texel.x, 0.0));
    float du = sample_depth(v_uv + vec2(0.0,  texel.y));
    float dd = sample_depth(v_uv + vec2(0.0, -texel.y));

    float lc = linearize_depth(dc);
    float ll = linearize_depth(dl);
    float lr = linearize_depth(dr);
    float lu = linearize_depth(du);
    float ld = linearize_depth(dd);

    // Relative depth difference; scale tolerance with distance so far objects stay outlined.
    float depth_diff = max(max(abs(lc - ll), abs(lc - lr)), max(abs(lc - lu), abs(lc - ld)));
    float depth_edge = smoothstep(0.02 * lc, 0.05 * lc + 0.01, depth_diff);

    vec3 nc = sample_normal(v_uv);
    vec3 nl = sample_normal(v_uv + vec2(-texel.x, 0.0));
    vec3 nr = sample_normal(v_uv + vec2( texel.x, 0.0));
    vec3 nu = sample_normal(v_uv + vec2(0.0,  texel.y));
    vec3 nd = sample_normal(v_uv + vec2(0.0, -texel.y));

    float normal_diff = (1.0 - dot(nc, nl)) + (1.0 - dot(nc, nr))
                      + (1.0 - dot(nc, nu)) + (1.0 - dot(nc, nd));
    float normal_edge = smoothstep(0.4, 0.8, normal_diff);

    float edge = clamp(max(depth_edge, normal_edge), 0.0, 1.0);
    out_color = vec4(mix(scene.rgb, outline_color, edge), 1.0);
}
