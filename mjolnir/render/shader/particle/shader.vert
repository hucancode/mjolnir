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

// Camera structure
struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    mat4 inv_view_projection;
};

// Bindless camera buffer set = 0
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

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

layout(push_constant) uniform ParticlePushConstants {
    uint camera_index;
} push;

// One vertex per live particle.
void main() {
    Particle p = particles[alive[gl_VertexIndex]];
    Camera camera = camera_buffer.cameras[push.camera_index];
    float ratio = p.life / p.max_life;
    outColor = mix(p.color_end, p.color_start, ratio);
    outTextureIndex = p.texture_index;
    gl_Position = camera.projection * camera.view * vec4(p.position, 1.0);
    float size = mix(p.size_end, p.size_start, ratio);
    float dist = clamp(length(camera.position.xyz - p.position), 1.0, 20.0);
    gl_PointSize = clamp(size / dist, 10.0, 100.0);
}
