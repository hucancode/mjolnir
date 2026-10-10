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
    vec4 frustum_planes[6];
};

// Bindless camera buffer set = 0
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

layout(set = 2, binding = 0) readonly buffer ParticleBuffer {
    Particle particles[];
};

layout(push_constant) uniform ParticlePushConstants {
    uint camera_index;
} push;

// One vertex per ring slot; dead slots land outside the clip volume.
void main() {
    Particle p = particles[gl_VertexIndex];
    if (p.life <= 0.0) {
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        gl_PointSize = 1.0;
        outColor = vec4(0.0);
        outTextureIndex = 0;
        return;
    }
    Camera camera = camera_buffer.cameras[push.camera_index];
    float ratio = p.life / p.max_life;
    outColor = mix(p.color_end, p.color_start, ratio);
    outTextureIndex = p.texture_index;
    gl_Position = camera.projection * camera.view * vec4(p.position, 1.0);
    float size = mix(p.size_end, p.size_start, ratio);
    float dist = clamp(length(camera.position.xyz - p.position), 1.0, 20.0);
    gl_PointSize = clamp(size / dist, 10.0, 100.0);
}
