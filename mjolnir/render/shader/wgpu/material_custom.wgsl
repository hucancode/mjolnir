// The interface of a user material fragment shader (render.material_shader_create). Follows
// common.wgsl and mesh.wgsl, which declare the scene buffers (views, nodes, materials), the
// uniforms `u` (u.camera_index) and VertexOut; the user source follows this and declares
// `fs_main(in: VertexOut) -> @location(0) vec4f`. A custom material is drawn in the forward
// pass over the lit image, depth-tested without writing depth.

// the drawn material's textures; a slot without one samples white
@group(1) @binding(0) var albedo_texture: texture_2d<f32>;
@group(1) @binding(1) var metallic_roughness_texture: texture_2d<f32>;
@group(1) @binding(2) var normal_texture: texture_2d<f32>;
@group(1) @binding(3) var emissive_texture: texture_2d<f32>;

// The material of the drawn node.
fn node_material(in: VertexOut) -> Material {
    return materials[nodes[in.node_index].material_id];
}
