// The interface of a user material shader (render.material_shader_create). Follows common.wgsl
// and mesh.wgsl, which declare the scene buffers (views, nodes, materials), the uniforms `u`
// (u.camera_index), VertexIn and VertexOut; the user sources follow this and declare
// `fs_main(in: VertexOut) -> @location(0) vec4f` and, to move the vertices,
// `vs_main(in: VertexIn) -> VertexOut`, which ends with material_vertex. A custom material is
// drawn in the forward pass over the lit image, depth-tested and writing depth unless its
// shader was made with depth_write = false. Read your own values from node_material(in).params (render.Material.params),
// the time from views[u.camera_index].time, the sun from views[u.camera_index].sun_direction and
// .sun_radiance, and the image size from views[u.camera_index].extent.

// the drawn material's textures; a slot without one samples white
@group(1) @binding(0) var albedo_texture: texture_2d<f32>;
@group(1) @binding(1) var metallic_roughness_texture: texture_2d<f32>;
@group(1) @binding(2) var normal_texture: texture_2d<f32>;
@group(1) @binding(3) var emissive_texture: texture_2d<f32>;

// The material of the drawn node.
fn node_material(in: VertexOut) -> Material {
    return materials[nodes[in.node_index].material_id];
}

// The vertex at model-space position and normal, moved by its node and seen by the camera.
fn material_vertex(in: VertexIn, position: vec3f, normal: vec3f) -> VertexOut {
    let world = nodes[in.node_index].world_matrix;
    let world_position = world * vec4f(position, 1.0);
    var out: VertexOut;
    out.normal = normalize(mat3_of(world) * normal);
    out.tangent = vec4f(normalize(mat3_of(world) * in.tangent.xyz), in.tangent.w);
    out.uv = in.uv;
    out.color = in.color;
    out.position = world_position.xyz;
    out.node_index = in.node_index;
    out.clip = clip_output(views[u.camera_index].view_projection * world_position);
    return out;
}

// The material of the vertex's node.
fn vertex_material(in: VertexIn) -> Material {
    return materials[nodes[in.node_index].material_id];
}
