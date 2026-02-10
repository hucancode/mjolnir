#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;
layout(location = 4) in vec4 inTangent;

struct Camera {
    mat4 view;
    mat4 projection;
    vec4 viewport_params;
    vec4 position;
    vec4 frustum_planes[6];
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};

layout(set = 2, binding = 0) readonly buffer WorldMatrices {
    mat4 world_matrices[];
};

struct NodeData {
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;  // For skinned meshes: bone matrix offset; For sprites: sprite index
    uint flags;
};

layout(set = 3, binding = 0) readonly buffer NodeBuffer {
    NodeData nodes[];
};

struct SpriteData {
    uint texture_index;
    uint frame_columns;
    uint frame_rows;
    uint frame_index;
};

layout(set = 4, binding = 0) readonly buffer SpriteBuffer {
    SpriteData sprites[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec2 outUV;
layout(location = 3) flat out uint outTextureIndex;

void main() {
    Camera camera = cameras[camera_index];
    uint node_index = uint(gl_InstanceIndex);
    mat4 world = world_matrices[node_index];
    NodeData node = nodes[node_index];
    uint sprite_index = node.attachment_data_index;
    SpriteData sprite = sprites[sprite_index];
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
    outColor = inColor;
    outPosition = worldPosition.xyz;
    outTextureIndex = sprite.texture_index;
    gl_Position = camera.projection * camera.view * worldPosition;
}
