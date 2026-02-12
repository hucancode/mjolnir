#version 450

layout(location = 0) out vec4 outColor;

layout(push_constant) uniform PushConstants {
    mat4 transform;
    vec4 color;
    uint camera_index;
    uint style;
};

// Simple hash function for pseudo-random color generation
float hash(uint x) {
    x = ((x >> 16) ^ x) * 0x45d9f3bu;
    x = ((x >> 16) ^ x) * 0x45d9f3bu;
    x = (x >> 16) ^ x;
    return float(x) / 4294967295.0;
}

vec3 hsv_to_rgb(vec3 hsv) {
    vec3 rgb = clamp(abs(mod(hsv.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return hsv.z * mix(vec3(1.0), rgb, hsv.y);
}

void main() {
    if (style == 1u) {
        // Random color mode - generate color from gl_PrimitiveID
        uint seed = uint(gl_PrimitiveID);
        float h = hash(seed);
        float s = 0.7 + hash(seed + 1u) * 0.3;
        float v = 0.8 + hash(seed + 2u) * 0.2;
        vec3 rgb = hsv_to_rgb(vec3(h, s, v));
        outColor = vec4(rgb, color.a);
    } else {
        // Uniform color or wireframe mode
        outColor = color;
    }
}
