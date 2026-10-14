#version 450

layout(location = 0) out vec4 outColor;

struct View {
    mat4 view;
    mat4 projection;
    mat4 view_projection;
    mat4 inv_view_projection; // rebuilds world positions from depth
    vec4 planes[6]; // normalized, pointing inward
    vec4 position;
    vec2 extent;
    float near;
    float far;
    uint attachments[6]; // this frame's bindless images, by AttachmentType
    uint pyramid; // bindless depth pyramid
    uint occlusion_mask; // bit t: material type t is tested against the pyramid
    uint list_stride;
    uint type_mask; // bit t: material type t is drawn
    uint require_flags; // node flags a drawn node has
    uint instance_tag; // OR-ed into first_instance above the node index
    uint layer;
    uint draw_list; // bindless draw lists the view appends to
    uint list_capacity; // draws per list
    uint _pad0;
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};

struct Segment {
    vec3 a;
    float expiry;
    vec3 b;
    uint _pad;
    vec4 color;
};

layout(set = 0, binding = 12) readonly buffer DebugLines {
    Segment segments[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
    float time; // render clock; a segment past its expiry is skipped
};

void main() {
    // vertex 2i is segment i's a end, 2i + 1 its b end
    Segment s = segments[gl_VertexIndex >> 1];
    if (s.expiry < time) {
        // both ends outside the clip volume: nothing is drawn
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        outColor = vec4(0.0);
        return;
    }
    vec3 position = (gl_VertexIndex & 1) == 0 ? s.a : s.b;
    gl_Position = views[camera_index].view_projection * vec4(position, 1.0);
    outColor = s.color;
}
