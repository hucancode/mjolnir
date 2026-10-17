// Debug lines pulled from the debug line table: vertex 2i is segment i's a end, 2i + 1 its b
// end. A segment past its expiry is moved outside the clip volume.

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> segments: array<DebugLineSegment>;

struct DebugLineSegment {
    a: vec3f,
    // render clock time the segment stops drawing after
    expiry: f32,
    b: vec3f,
    _pad0: u32,
    color: vec4f,
}

struct DebugLinePush {
    camera_index: u32,
}
@group(2) @binding(0) var<uniform> u: DebugLinePush;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) color: vec4f,
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> VertexOut {
    let s = segments[i >> 1u];
    var out: VertexOut;
    if (s.expiry < views[u.camera_index].time) {
        out.clip = CLIP_DISCARD;
        return out;
    }
    let position = select(s.b, s.a, (i & 1u) == 0u);
    out.clip = clip_output(views[u.camera_index].view_projection * vec4f(position, 1.0));
    out.color = s.color;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return in.color;
}
