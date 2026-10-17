#version 450

struct Particle {
    vec3 position;
    float size_start;
    vec3 velocity;
    float size_end;
    vec4 color_start;
    vec4 color_end;
    float life;
    float max_life;
    float weight;
    uint texture_index;
};

layout (location = 0) out vec4 outColor;
layout (location = 1) out flat uint outTextureIndex;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_PointSize;
};

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
    uint images[6]; // this frame's bindless images, by CameraImage
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

layout(set = 0, binding = 8) readonly buffer ParticleBuffer {
    Particle particles[];
};

// Indirect draw of the live particles, then their indices.
layout(set = 0, binding = 9) readonly buffer AliveBuffer {
    uint vertex_count;
    uint instance_count;
    uint first_vertex;
    uint first_instance;
    uint alive[];
};

layout(push_constant) uniform ParticleDrawPush {
    uint camera_index;
} push;

// One vertex per live particle.
void main() {
    Particle p = particles[alive[gl_VertexIndex]];
    View camera = views[push.camera_index];
    float ratio = p.life / p.max_life;
    outColor = mix(p.color_end, p.color_start, ratio);
    outTextureIndex = p.texture_index;
    gl_Position = camera.projection * camera.view * vec4(p.position, 1.0);
    float size = mix(p.size_end, p.size_start, ratio);
    float dist = clamp(length(camera.position.xyz - p.position), 1.0, 20.0);
    gl_PointSize = clamp(size / dist, 10.0, 100.0);
}
