#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;
const uint INVALID_TEXTURE = 0u;

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) flat in uint v_light;
layout(location = 0) out vec4 outColor;

// View.attachments indices (AttachmentType)
const uint ATTACHMENT_NORMAL = 1u;
const uint ATTACHMENT_ALBEDO = 2u;
const uint ATTACHMENT_METALLIC_ROUGHNESS = 3u;
const uint ATTACHMENT_EMISSIVE = 4u;
const uint ATTACHMENT_DEPTH = 5u;

struct View {
    mat4 view;
    mat4 projection;
    mat4 view_projection;
    mat4 inv_view_projection; // rebuilds world positions from depth
    vec4 planes[6]; // normalized, pointing inward
    vec4 position;
    vec2 extent;
    float near;
    float far;
    uint attachments[6]; // this frame's bindless images, by AttachmentType
    uint pyramid; // bindless depth pyramid
    uint occlusion_mask; // bit t: material type t is tested against the pyramid
    uint list_stride;
    uint type_mask; // bit t: material type t is drawn
    uint require_flags; // node flags a drawn node has
    uint instance_tag; // OR-ed into first_instance above the node index
    uint layer;
    uint draw_list; // bindless draw lists the view appends to
    uint list_capacity; // draws per list
    uint _pad0;
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 0) uniform textureCube cube_textures[]; // aliases textures

struct Light {
    vec4 color;
    vec3 position;
    float radius;
    vec3 direction;
    float angle_inner;
    float angle_outer;
    uint shadow_map;
    float shadow_texel;
    uint _pad0;
};

layout(set = 0, binding = 10) readonly buffer LightBuffer {
    Light lights[];
};

layout(push_constant) uniform PushConstant {
    uint camera_index;
    uint irradiance_index;
    uint prefilter_index;
    uint brdf_lut_index;
    uint environment_index;
    float skybox_intensity;
    float skybox_blur;
};

float prefilter_max_lod() {
    return float(textureQueryLevels(samplerCube(cube_textures[prefilter_index], samplers[SAMPLER_LINEAR_CLAMP])) - 1);
}

vec3 fresnel_schlick_roughness(float cos_theta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0)
        * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

vec2 dirToEquirectUv(vec3 dir) {
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

// World position of the G-buffer texel at framebuffer uv, rebuilt from its
// depth. Clip-space y points down, so ndc follows uv on both axes.
vec3 worldPosition(View camera, vec2 uv, float depth) {
    vec4 p = camera.inv_view_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return p.xyz / p.w;
}

vec3 sample_skybox(View camera, vec2 uv) {
    vec2 ndc = uv * 2.0 - 1.0;
    vec4 world_far = camera.inv_view_projection * vec4(ndc, 1.0, 1.0);
    vec3 dir = normalize(world_far.xyz / world_far.w - camera.position.xyz);
    float b = clamp(skybox_blur, 0.0, 1.0);
    if (b <= 0.0 || prefilter_index == INVALID_TEXTURE) {
        vec2 eq_uv = dirToEquirectUv(dir);
        return textureLod(sampler2D(textures[environment_index], samplers[SAMPLER_LINEAR_REPEAT]), eq_uv, 0.0).rgb;
    }
    float cube_lod = b * prefilter_max_lod();
    return textureLod(samplerCube(cube_textures[prefilter_index], samplers[SAMPLER_LINEAR_CLAMP]), dir, cube_lod).rgb;
}

void main() {
    View camera = views[camera_index];
    float ibl_intensity = lights[v_light].color.a;
    vec2 uv = gl_FragCoord.xy / camera.extent;
    float depth = texelFetch(sampler2D(textures[camera.attachments[ATTACHMENT_DEPTH]], samplers[SAMPLER_NEAREST_CLAMP]), ivec2(gl_FragCoord.xy), 0).r;

    // Background (depth left at the far clear value): the skybox, if any.
    // Alpha 0 keeps the cleared alpha under the additive blend.
    if (depth >= 1.0) {
        if (skybox_intensity > 0.0 && environment_index != INVALID_TEXTURE) {
            vec3 sky = sample_skybox(camera, uv) * skybox_intensity;
            outColor = vec4(sky, 0.0);
            return;
        }
        discard;
    }
    vec3 position = worldPosition(camera, uv, depth);

    vec3 normal = texture(sampler2D(textures[camera.attachments[ATTACHMENT_NORMAL]], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz * 2.0 - 1.0;
    vec3 albedo = texture(sampler2D(textures[camera.attachments[ATTACHMENT_ALBEDO]], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[camera.attachments[ATTACHMENT_METALLIC_ROUGHNESS]], samplers[SAMPLER_NEAREST_CLAMP]), uv).rg;
    float metallic = mr.r;
    float roughness = mr.g;
    vec3 emissive = texture(sampler2D(textures[camera.attachments[ATTACHMENT_EMISSIVE]], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;

    vec3 V = normalize(camera.position.xyz - position);
    vec3 R = reflect(-V, normal);
    float NdotV = max(dot(normal, V), 0.0);

    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 F = fresnel_schlick_roughness(NdotV, F0, roughness);

    vec3 ambient = vec3(0.0);
    if (ibl_intensity > 0.0 && prefilter_index != INVALID_TEXTURE) {
        vec3 irradiance = texture(samplerCube(cube_textures[irradiance_index], samplers[SAMPLER_LINEAR_CLAMP]), normal).rgb;
        vec3 diffuse = irradiance * albedo;
        vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);

        vec3 prefiltered = textureLod(
            samplerCube(cube_textures[prefilter_index], samplers[SAMPLER_LINEAR_CLAMP]),
            R,
            roughness * prefilter_max_lod()
        ).rgb;
        vec2 brdf = texture(
            sampler2D(textures[brdf_lut_index], samplers[SAMPLER_LINEAR_CLAMP]),
            vec2(NdotV, roughness)
        ).rg;
        vec3 specular = prefiltered * (F * brdf.x + brdf.y);

        ambient = (kD * diffuse + specular) * ibl_intensity;
    }

    outColor = vec4(ambient + emissive, 0.0);
}
