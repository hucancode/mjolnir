// The interface of a user material shader (render.material_shader_create): the scene buffers
// it reads, the bindless textures and, for a fragment shader, the mesh vertex stage's outputs
// and the color output. A custom material is drawn in the forward pass over the lit image,
// depth-tested, writing depth when its shader does not blend. Read your own values from
// node_material().params (render.Material.params), the time from camera_view().time, the sun
// from camera_view().sun_direction and .sun_radiance and the image size from
// camera_view().extent.
//
//     #version 450
//     #include "material.glsl"
//     void main() {
//         Material m = node_material();
//         float pulse = 0.5 + 0.5 * sin(camera_view().time * m.params[0].x);
//         out_color = m.base_color_factor * pulse;
//     }
//
// A vertex shader that moves the mesh's vertices defines MATERIAL_VERTEX first: it reads
// in_position, in_normal, in_color, in_uv and in_tangent (model space) and ends with
// material_vertex(position, normal).
//
// Compile with glslc --target-env=vulkan1.3 -I <this directory>.

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
    // the rest is render's own; don't rely on it
    uint images[6];
    uint pyramid;
    uint occlusion_mask;
    uint list_stride;
    uint type_mask;
    uint require_flags;
    uint instance_tag;
    uint layer;
    uint draw_list;
    uint list_capacity;
    float time; // render's clock in seconds
    vec4 sun_radiance; // Renderer.sun: color * intensity, 0 when off
    vec4 sun_direction; // towards the sun
};

// render.Material: a custom material reads params, and any other field it likes
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
    uint type; // MaterialType
    vec4 params[2]; // a .CUSTOM shader's own values
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

#ifdef MATERIAL_VERTEX
// model space
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in vec4 in_tangent;

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec3 out_normal;
layout(location = 3) out vec2 out_uv;
layout(location = 4) out vec4 out_tangent;
layout(location = 5) flat out uint out_node_index;

// The material of the drawn node.
Material node_material() {
    return materials[nodes[gl_InstanceIndex].material_id];
}

// Emits the vertex at model-space position and normal, moved by its node and seen by the camera.
void material_vertex(vec3 position, vec3 normal) {
    mat4 world = nodes[gl_InstanceIndex].world_matrix;
    vec4 world_position = world * vec4(position, 1.0);
    out_position = world_position.xyz;
    out_color = in_color;
    out_normal = normalize(mat3(world) * normal);
    out_uv = in_uv;
    out_tangent = vec4(normalize(mat3(world) * in_tangent.xyz), in_tangent.w);
    out_node_index = uint(gl_InstanceIndex);
    gl_Position = views[camera_index].view_projection * world_position;
}
#else
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
#endif

// The drawing camera's view.
View camera_view() {
    return views[camera_index];
}

// Texture `index` at uv, repeating; white for NO_TEXTURE.
vec4 sample_texture(uint index, vec2 uv) {
    if (index == NO_TEXTURE) return vec4(1.0);
    return texture(sampler2D(textures[nonuniformEXT(index)], samplers[SAMPLER_LINEAR_REPEAT]), uv);
}
