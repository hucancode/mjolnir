// The interface of a user material fragment shader (render.material_shader_create): the
// mesh vertex stage's outputs, the color output, the scene buffers it reads and the
// bindless textures. A custom material is drawn in the forward pass over the lit image,
// depth-tested without writing depth.
//
//     #version 450
//     #include "material.glsl"
//     void main() {
//         Material m = node_material();
//         out_color = m.base_color_factor * max(dot(normalize(in_normal), vec3(0, 1, 0)), 0.0);
//     }
//
// Compile with glslc -I <this directory>.

#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

// texture index of a material slot without a texture
const uint NO_TEXTURE = 0u;

struct View {
    mat4 view;
    mat4 projection;
    mat4 view_projection;
    mat4 inv_view_projection;
    vec4 planes[6];
    vec4 position; // world position of the camera
    vec2 extent;
    float near;
    float far;
    uint attachments[6];
    uint pyramid;
    uint occlusion_mask;
    uint list_stride;
    uint type_mask;
    uint require_flags;
    uint instance_tag;
    uint layer;
    uint draw_list;
    uint list_capacity;
    uint _view_pad;
};

// render.Material; for a custom material every field but `type` and `shader` is the shader's
struct Material {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint shader;
    vec4 base_color_factor;
    uint frame_columns;
    uint frame_rows;
    uint frame_index;
    uint type;
};

struct Node {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
    uint skin_vertex_base;
    uint _node_pad[3];
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};

layout(set = 0, binding = 1) readonly buffer NodeBuffer {
    Node nodes[];
};

layout(set = 0, binding = 3) readonly buffer MaterialBuffer {
    Material materials[];
};

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform MeshPush {
    uint camera_index;
};

// world space
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec4 in_color;
layout(location = 2) in vec3 in_normal;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in vec4 in_tangent;
layout(location = 5) flat in uint in_node_index;

layout(location = 0) out vec4 out_color;

// The material of the drawn node.
Material node_material() {
    return materials[nodes[in_node_index].material_id];
}

// The drawing camera's view.
View camera_view() {
    return views[camera_index];
}

// Texture `index` at uv, repeating; white for NO_TEXTURE.
vec4 sample_texture(uint index, vec2 uv) {
    if (index == NO_TEXTURE) return vec4(1.0);
    return texture(sampler2D(textures[nonuniformEXT(index)], samplers[SAMPLER_LINEAR_REPEAT]), uv);
}
