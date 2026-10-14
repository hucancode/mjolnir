// Bindings and helpers of the IBL precompute (pass_ibl.odin): each dispatch writes one cube
// level as six storage layers, one thread per texel per face. The file of each step follows,
// declaring `source` (@group(3) @binding(0)): the equirect map, or the environment cube.

@group(3) @binding(1) var destination: texture_storage_2d_array<rgba16float, write>;

struct PrecomputeUniforms {
    // edge length of the destination level
    face_size: u32,
    // the irradiance sample step, or the prefilter roughness
    value: f32,
    // GGX samples per texel (prefilter)
    sample_count: u32,
}
@group(2) @binding(0) var<uniform> u: PrecomputeUniforms;

// Direction through texel uv in [-1, 1] of cube face `face` (+X, -X, +Y, -Y, +Z, -Z).
fn face_dir(face: u32, uv: vec2f) -> vec3f {
    var d: vec3f;
    switch (face) {
        case 0u: { d = vec3f(1.0, -uv.y, -uv.x); }
        case 1u: { d = vec3f(-1.0, -uv.y, uv.x); }
        case 2u: { d = vec3f(uv.x, 1.0, uv.y); }
        case 3u: { d = vec3f(uv.x, -1.0, -uv.y); }
        case 4u: { d = vec3f(uv.x, -uv.y, 1.0); }
        default: { d = vec3f(-uv.x, -uv.y, -1.0); }
    }
    return normalize(d);
}

// The texel's direction, false past the level's edge.
fn texel_dir(gid: vec3u, dir: ptr<function, vec3f>) -> bool {
    if (gid.x >= u.face_size || gid.y >= u.face_size || gid.z >= 6u) {
        return false;
    }
    let uv = (vec2f(gid.xy) + 0.5) / f32(u.face_size) * 2.0 - 1.0;
    *dir = face_dir(gid.z, uv);
    return true;
}
