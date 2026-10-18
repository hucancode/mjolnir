#version 450
#extension GL_ARB_shader_viewport_layer_array : require

// Draws one node into one shadow view's atlas layer. The cull tags each draw:
// first_instance = node | view << 16.

layout(location = 0) in vec3 inPosition;

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

void main() {
    uint node_index = uint(gl_InstanceIndex) & 0xFFFFu;
    View view = views[uint(gl_InstanceIndex) >> 16u];
    Node node = nodes[node_index];
    mat4 world = node.world_matrix;
    MeshData mesh = meshes[node.mesh_id];
    vec4 model_position;
    bool is_skinned = (node.flags & NODE_FLAG_SKINNED) != 0u; // only set on a skinned mesh
    if (is_skinned) {
        model_position = vec4(skinned[node.skin_vertex_base + uint(gl_VertexIndex - mesh.vertex_offset)].position.xyz, 1.0);
    } else {
        model_position = vec4(inPosition, 1.0);
    }
    vec4 world_position = world * model_position;
    gl_Position = view.view_projection * world_position;
    gl_Layer = int(view.layer);
}
