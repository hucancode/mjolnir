// Lights a forcefield of solid glowing panels: each quad of the faceted sphere has a bright
// frame and an inset trim, flickers on its own, flares where it pops out, and brightens toward
// the silhouette. Reads
//   params[0].x    1 pops quads out (field.vert)
//   params[0].y    1 draws the edges of the mesh's triangles instead
//   params[0].zw   the sphere's segments and rings (render.make_sphere)
//   params[2].rgb  the color of the field
// It follows field_vert.wgsl and uses its TAU, random and pop.

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let m = node_material(in);
    let view = views[u.camera_index];
    let t = view.time;
    let g = in.uv * m.params[0].zw;
    let cell = floor(g);
    let f = g - cell;
    let w = fwidth(g);
    // pixels to the quad's border, and to its trim a fifth of the way in
    let border = min(f, 1.0 - f) / w;
    let frame = min(border.x, border.y);
    let inside = min(f, 1.0 - f) - 0.2;
    let trim = abs(min(inside.x / w.x, inside.y / w.y));
    let diagonal = abs(f.x + f.y - 1.0) / fwidth(g.x + g.y);
    let color = m.params[2].rgb;

    if (m.params[0].y > 0.5) {
        if (min(frame, diagonal) > 0.75) {
            discard;
        }
        return vec4f(color * 2.0, 1.0);
    }
    let popped = m.params[0].x * pop(cell, m.params[0].w);
    let flicker = 0.75 + 0.25 * sin(t * (2.0 + 3.0 * random(cell, 7.0)) + TAU * random(cell, 9.0));
    let facing = abs(dot(normalize(in.normal), normalize(view.position.xyz - in.position)));
    let rim = pow(1.0 - facing, 3.0);
    let lines = 1.0 - smoothstep(0.0, 1.5, frame);
    let trims = 1.0 - smoothstep(0.0, 1.0, trim);

    let light = 0.1 * flicker + 0.6 * rim + 0.35 * trims * flicker + 2.5 * lines + 1.5 * popped;
    return vec4f(color * light, 1.0);
}
