// Sprite: a camera-facing billboard at the node's position, scaled by its world scale, showing
// cell frame_index (row-major) of the albedo sprite sheet.

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> nodes: array<Node>;
@group(0) @binding(3) var<storage, read> materials: array<Material>;

@group(1) @binding(0) var albedo_texture: texture_2d<f32>;

struct MeshPush {
    camera_index: u32,
}
@group(2) @binding(0) var<uniform> u: MeshPush;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) position: vec3f,
    @location(1) color: vec4f,
    @location(2) uv: vec2f,
}

@vertex
fn vs_main(
    @location(0) position: vec3f,
    @location(2) color: vec4f,
    @location(3) uv: vec2f,
    @location(5) node_index: u32,
) -> VertexOut {
    let camera = views[u.camera_index];
    let node = nodes[node_index];
    let world = node.world_matrix;
    let sprite = materials[node.material_id];
    let camera_right = vec3f(camera.view[0][0], camera.view[1][0], camera.view[2][0]);
    let camera_up = vec3f(camera.view[0][1], camera.view[1][1], camera.view[2][1]);
    let world_pos = (world * vec4f(0.0, 0.0, 0.0, 1.0)).xyz;
    let scale_x = length(vec3f(world[0][0], world[1][0], world[2][0]));
    let scale_y = length(vec3f(world[0][1], world[1][1], world[2][1]));
    let vertex_pos = world_pos + camera_right * (position.x * scale_x) + camera_up * (position.y * scale_y);
    let frame_size = vec2f(1.0 / f32(sprite.frame_columns), 1.0 / f32(sprite.frame_rows));
    let column = sprite.frame_index % sprite.frame_columns;
    let row = sprite.frame_index / sprite.frame_columns;
    var out: VertexOut;
    out.uv = uv * frame_size + vec2f(f32(column), f32(row)) * frame_size;
    out.color = color * sprite.base_color_factor;
    out.position = vertex_pos;
    out.clip = clip_output(camera.projection * camera.view * vec4f(vertex_pos, 1.0));
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return textureSample(albedo_texture, nearest_clamp, in.uv) * in.color;
}
