// Shapes a sphere into the head: flat and long, tapering to the snout, the back of it at the
// node. Reads
//   params[0].x  how far the jaw hangs open, in radians
// and hands the fragment shader (up, along, around, mouth) of the head in color, around
// measured across the head in turns of the body.

const RADIUS: f32 = 0.45;
const SIZE = vec3f(1.3, 0.8, 1.9) * RADIUS;
// the jaw's hinge, (y, z)
const HINGE = vec2f(0.8 * SIZE.y, -0.45);

@vertex
fn vs_main(in: VertexIn) -> VertexOut {
    let m = vertex_material(in);
    let jaw = m.params[0].x;
    let p = normalize(in.position);
    let snout = clamp(-p.z, 0.0, 1.0);
    let size = SIZE * vec3f(1.0 - 0.4 * snout * snout, (1.0 - 0.25 * snout) * select(0.8, 1.0, p.y > 0.0), 1.0);
    var position = p * size + vec3f(0.0, HINGE.x, -0.55 * SIZE.z);
    var normal = normalize(p / size);

    let angle = jaw * step(p.y, -0.001) * (1.0 - smoothstep(HINGE.y - 0.1, HINGE.y + 0.2, position.z));
    let hang = mat2x2f(cos(angle), -sin(angle), sin(angle), cos(angle));
    position = vec3f(position.x, HINGE + hang * (position.yz - HINGE));
    normal = vec3f(normal.x, hang * normal.yz);

    let mouth = step(abs(p.y), 0.001) * step(position.z, HINGE.y) * (1.0 + 8.0 * jaw);
    var out = material_vertex(in, position, normal);
    out.color = vec4f(p.y, position.z, position.x / (6.2831853 * RADIUS), mouth);
    return out;
}
