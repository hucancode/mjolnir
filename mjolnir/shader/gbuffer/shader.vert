#version 450

// Shader feature bit flags (must match Odin ShaderFeatures enum)
const uint FEATURE_ALBEDO_TEXTURE = 1u << 0u;
const uint FEATURE_METALLIC_ROUGHNESS_TEXTURE = 1u << 1u;
const uint FEATURE_NORMAL_TEXTURE = 1u << 2u;
const uint FEATURE_EMISSIVE_TEXTURE = 1u << 3u;
const uint FEATURE_OCCLUSION_TEXTURE = 1u << 4u;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;
layout(location = 4) in vec4 inTangent;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};
// set 1 (textures), not available in vertex shader
layout(set = 2, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

// Material buffer set = 3
struct MaterialData {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint material_type;
    uint features;
    vec4 base_color_factor;
    uint padding[2];
};

layout(set = 3, binding = 0) readonly buffer MaterialBuffer {
    MaterialData materials[];
};
layout(set = 4, binding = 0) readonly buffer WorldMatrixBuffer {
    mat4 world_matrices[];
};

// NodeData structure (must match Odin struct)
struct NodeData {
    uint material_id;
    uint mesh_id;
    uint bone_matrix_offset;
    uint _padding;
};

struct MeshData {
    vec3 aabb_min;
    uint is_skinned;
    vec3 aabb_max;
    uint vertex_skinning_offset;
};

struct VertexSkinningData {
    uvec4 joints;
    vec4 weights;
};

// NEW: NodeData buffer (set 5)
layout(set = 5, binding = 0) readonly buffer NodeDataBuffer {
    NodeData node_data[];
};

// NEW: MeshData buffer (set 6) - contains AABB + skinning metadata
layout(set = 6, binding = 0) readonly buffer MeshDataBuffer {
    MeshData mesh_data_array[];
};

// NEW: Vertex skinning buffer (set 7) - contains joints + weights per vertex
layout(set = 7, binding = 0) readonly buffer VertexSkinningBuffer {
    VertexSkinningData vertex_skinning_data[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
    uint padding[31];
};

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec3 outNormal;
layout(location = 3) out vec2 outUV;
layout(location = 4) out vec4 outTangent;
layout(location = 5) flat out uint outNodeId;

void main() {
    // In Vulkan indirect draws with instanceCount=1:
    // gl_InstanceIndex = instanceIndex + firstInstance = 0 + firstInstance = firstInstance
    // Since firstInstance = node_id, gl_InstanceIndex correctly gives us node_id
    uint node_id = uint(gl_InstanceIndex);

    // Bounds check to prevent GPU crashes
    if (node_id >= node_data.length()) {
        gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    NodeData node = node_data[node_id];

    // Bounds check mesh_id
    if (node.mesh_id >= mesh_data_array.length()) {
        gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    MeshData mesh_info = mesh_data_array[node.mesh_id];

    // Get material data for other features (non-skinning)
    MaterialData material = materials[node.material_id];
    // Skinning is a mesh feature, not a material feature
    bool is_skinned = mesh_info.is_skinned != 0;

    Camera camera = cameras[camera_index];

    // Calculate skinned position if needed
    vec4 modelPosition = vec4(inPosition, 1.0);
    vec3 modelNormal = inNormal;
    vec4 modelTangent = inTangent;

    if (is_skinned) {
        // Manual lookup using mesh offset + vertex index
        uint skinning_index = mesh_info.vertex_skinning_offset + gl_VertexIndex;
        VertexSkinningData skinning_data = vertex_skinning_data[skinning_index];
        uvec4 joints = skinning_data.joints;
        vec4 weights = skinning_data.weights;

        // Add bone matrix offset to joint indices
        uvec4 bone_indices = joints + uvec4(node.bone_matrix_offset);

        // Bounds check bone indices
        if (bone_indices.x >= bones.length() || bone_indices.y >= bones.length() ||
            bone_indices.z >= bones.length() || bone_indices.w >= bones.length()) {
            // Use identity matrix for invalid bone indices
            modelPosition = vec4(inPosition, 1.0);
            modelNormal = inNormal;
            modelTangent = inTangent;
        } else {
            mat4 skinMatrix =
                weights.x * bones[bone_indices.x] +
                weights.y * bones[bone_indices.y] +
                weights.z * bones[bone_indices.z] +
                weights.w * bones[bone_indices.w];

            modelPosition = skinMatrix * vec4(inPosition, 1.0);
            modelNormal = mat3(skinMatrix) * inNormal;
            modelTangent = skinMatrix * inTangent;
        }
    }

    // Transform to world space
    // Bounds check world_matrices access
    if (node_id >= world_matrices.length()) {
        gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    mat4 world = world_matrices[node_id];
    vec4 worldPosition = world * modelPosition;

    // Output transformed data
    outNormal = normalize(mat3(world) * modelNormal);
    outTangent = normalize(world * modelTangent);
    outUV = inUV;
    outColor = inColor;
    outPosition = worldPosition.xyz;
    outNodeId = node_id;  // Pass node_id to fragment shader

    gl_Position = camera.projection * camera.view * worldPosition;
}
