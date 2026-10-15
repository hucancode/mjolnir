// The vertex shader of mesh materials (scene group MESH), skinned by the node's bone palette.

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> nodes: array<Node>;
@group(0) @binding(2) var<storage, read> meshes: array<Mesh>;
@group(0) @binding(3) var<storage, read> materials: array<Material>;
@group(0) @binding(4) var<storage, read> bones: array<mat4x4f>;
@group(0) @binding(5) var<storage, read> skinning: array<Skinning>;

struct MeshUniforms {
    camera_index: u32,
}
@group(2) @binding(0) var<uniform> u: MeshUniforms;

struct VertexIn {
    @builtin(vertex_index) vertex_index: u32,
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
    @location(3) uv: vec2f,
    @location(4) tangent: vec4f,
    // the draw's node (the candidate list, instance step)
    @location(5) node_index: u32,
}

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) position: vec3f,
    @location(1) color: vec4f,
    @location(2) normal: vec3f,
    @location(3) uv: vec2f,
    @location(4) tangent: vec4f,
    @location(5) @interpolate(flat) node_index: u32,
}

fn mat3_of(m: mat4x4f) -> mat3x3f {
    return mat3x3f(m[0].xyz, m[1].xyz, m[2].xyz);
}

@vertex
fn vs_main(in: VertexIn) -> VertexOut {
    let camera = views[u.camera_index];
    let node = nodes[in.node_index];
    let world = node.world_matrix;
    var model_position = vec4f(in.position, 1.0);
    var model_normal = in.normal;
    var model_tangent = in.tangent;
    if ((node.flags & NODE_FLAG_SKINNED) != 0u) {
        let mesh = meshes[node.mesh_id];
        let local_index = i32(in.vertex_index) - mesh.vertex_offset;
        let skin = skinning[mesh.skinning_offset + u32(local_index)];
        let joints = skin.joints + vec4u(node.attachment_data_index);
        let skin_matrix =
            skin.weights.x * bones[joints.x] +
            skin.weights.y * bones[joints.y] +
            skin.weights.z * bones[joints.z] +
            skin.weights.w * bones[joints.w];
        model_position = skin_matrix * model_position;
        model_normal = mat3_of(skin_matrix) * in.normal;
        model_tangent = vec4f(mat3_of(skin_matrix) * in.tangent.xyz, in.tangent.w);
    }
    let world_position = world * model_position;
    var out: VertexOut;
    out.normal = normalize(mat3_of(world) * model_normal);
    out.tangent = vec4f(normalize(mat3_of(world) * model_tangent.xyz), model_tangent.w);
    out.uv = in.uv;
    out.color = in.color;
    out.position = world_position.xyz;
    out.node_index = in.node_index;
    out.clip = clip_output(camera.projection * camera.view * world_position);
    return out;
}
