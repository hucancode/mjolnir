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
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};

struct Material {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint _pad;
    vec4 base_color_factor;
    uint frame_columns;
    uint frame_rows;
    uint frame_index;
    uint type; // MaterialType
    vec4 params[2]; // a .CUSTOM shader's own values
};

layout(set = 0, binding = 3) readonly buffer MaterialBuffer {
    Material materials[];
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

layout(push_constant) uniform MeshPush {
    uint camera_index;
};

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec2 outUV;
layout(location = 3) flat out uint outTextureIndex;

void main() {
    View camera = views[camera_index];
    uint node_index = uint(gl_InstanceIndex);
    Node node = nodes[node_index];
    mat4 world = node.world_matrix;
    Material sprite = materials[node.material_id];
    vec3 camera_right = vec3(camera.view[0][0], camera.view[1][0], camera.view[2][0]);
    vec3 camera_up = vec3(camera.view[0][1], camera.view[1][1], camera.view[2][1]);
    // Extract position from world matrix
    vec3 world_pos = (world * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    // Extract scale from world matrix (length of basis vectors)
    float scale_x = length(vec3(world[0][0], world[1][0], world[2][0]));
    float scale_y = length(vec3(world[0][1], world[1][1], world[2][1]));
    // Apply scale to billboard vertices
    vec3 vertex_pos = world_pos + camera_right * (inPosition.x * scale_x) + camera_up * (inPosition.y * scale_y);
    vec4 worldPosition = vec4(vertex_pos, 1.0);
    // Calculate UV from frame dimensions and index
    float frame_width = 1.0 / float(sprite.frame_columns);
    float frame_height = 1.0 / float(sprite.frame_rows);
    uint column = sprite.frame_index % sprite.frame_columns;
    uint row = sprite.frame_index / sprite.frame_columns;
    vec2 uv_offset = vec2(float(column) * frame_width, float(row) * frame_height);
    vec2 uv_size = vec2(frame_width, frame_height);
    outUV = inUV * uv_size + uv_offset;
    outColor = inColor * sprite.base_color_factor;
    outPosition = worldPosition.xyz;
    outTextureIndex = sprite.albedo_index;
    gl_Position = camera.projection * camera.view * worldPosition;
}
