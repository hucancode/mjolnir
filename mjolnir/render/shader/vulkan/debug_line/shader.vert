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
    float time; // render's clock in seconds
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};

struct DebugLineSegment {
    vec3 a;
    float expiry;
    vec3 b;
    uint _pad;
    vec4 color;
};

layout(set = 0, binding = 12) readonly buffer DebugLines {
    DebugLineSegment segments[];
};

layout(push_constant) uniform DebugLinePush {
    uint camera_index;
};

void main() {
    // vertex 2i is segment i's a end, 2i + 1 its b end
    DebugLineSegment s = segments[gl_VertexIndex >> 1];
    // a segment past its expiry on the render clock is skipped
    if (s.expiry < views[camera_index].time) {
        // both ends outside the clip volume: nothing is drawn
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        outColor = vec4(0.0);
        return;
    }
    vec3 position = (gl_VertexIndex & 1) == 0 ? s.a : s.b;
    gl_Position = views[camera_index].view_projection * vec4(position, 1.0);
    outColor = s.color;
}
