#version 450

layout(location = 0) out vec3 fragColor;

vec2 positions[4] = vec2[](
        vec2(-0.5, -0.5),
        vec2(0.5, -0.5),
        vec2(0.5, 0.5),
        vec2(-0.5, 0.5)
    );
int indices[6] = int[](
        0, 1, 2,
        2, 3, 0
    );

vec3 colors[4] = vec3[](
        // Mauve 203, 166, 247
        vec3(0.79296875, 0.6484375, 0.96484375),
        // Red 243, 139, 168
        vec3(0.953125, 0.054296875, 0.66015625),
        // Maroon 235, 160, 172
        vec3(0.91796875, 0.625, 0.671875),
        // Peach 250, 179, 135
        vec3(0.9765625, 0.69921875, 0.52734375)
    );

void main() {
    int i = indices[gl_VertexIndex];
    gl_Position = vec4(positions[i], 0.0, 1.0);
    fragColor = colors[i];
}
