#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;
layout(location = 4) in vec4 inTangent;

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
    uint images[6]; // this frame's bindless images, by CameraImage
    uint pyramid; // bindless depth pyramid
    uint occlusion_mask; // bit t: material type t is tested against the pyramid
    uint list_stride;
    uint type_mask; // bit t: material type t is drawn
    uint require_flags; // node flags a drawn node has
    uint instance_tag; // OR-ed into first_instance above the node index
    uint layer;
    uint draw_list; // bindless draw lists the view appends to
    uint list_capacity; // draws per list
    float time; // render's clock in seconds
    vec4 sun_radiance; // Renderer.sun: color * intensity, 0 when off
    vec4 sun_direction; // towards the sun
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};
struct Node {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
    uint skin_vertex_base; // first of the skinned vertices when skinned
    uint _node_pad[3];
};

layout(set = 0, binding = 1) readonly buffer NodeBuffer {
    Node nodes[];
};

const uint NODE_FLAG_SKINNED = 1u << 2; // the node holds a bone range

struct MeshData {
    vec3 aabb_min;
    uint index_count;
    vec3 aabb_max;
    uint first_index;
    int vertex_offset;
    uint vertex_skinning_offset;
    uint flags;
    uint _padding;
};

layout(set = 0, binding = 2) readonly buffer MeshBuffer {
    MeshData meshes[];
};

// what the skinning pass wrote; w of position and normal is unused
struct SkinnedVertex {
    vec4 position;
    vec4 normal;
    vec4 tangent;
};

layout(set = 0, binding = 16) readonly buffer SkinnedVertexBuffer {
    SkinnedVertex skinned[];
};

layout(push_constant) uniform MeshPush {
    uint camera_index;
};

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec3 outNormal;
layout(location = 3) out vec2 outUV;
layout(location = 4) out vec4 outTangent;
layout(location = 5) flat out uint outNodeIndex;

void main() {
    View camera = views[camera_index];
    uint node_index = uint(gl_InstanceIndex);
    Node node = nodes[node_index];
    mat4 world = node.world_matrix;
    MeshData mesh = meshes[node.mesh_id];

    vec4 modelPosition;
    vec3 modelNormal;
    vec4 modelTangent;
    bool is_skinned = (node.flags & NODE_FLAG_SKINNED) != 0u; // only set on a skinned mesh
    if (is_skinned) {
        SkinnedVertex skin = skinned[node.skin_vertex_base + uint(gl_VertexIndex - mesh.vertex_offset)];
        modelPosition = vec4(skin.position.xyz, 1.0);
        modelNormal = skin.normal.xyz;
        modelTangent = skin.tangent;
    } else {
        modelPosition = vec4(inPosition, 1.0);
        modelNormal = inNormal;
        modelTangent = inTangent;
    }
    vec4 worldPosition = world * modelPosition;
    outNormal = normalize(mat3(world) * modelNormal);
    outTangent = vec4(normalize(mat3(world) * modelTangent.xyz), modelTangent.w);
    outUV = inUV;
    outColor = inColor;
    outPosition = worldPosition.xyz;
    outNodeIndex = node_index;
    gl_Position = camera.projection * camera.view * worldPosition;
}
