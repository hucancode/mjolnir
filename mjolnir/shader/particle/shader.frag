#version 450

layout (binding = 0) uniform sampler2D particleTexture;

layout (location = 0) in vec4 inColor;
layout (location = 0) out vec4 outFragColor;

void main() {
    // Sample the particle texture using point coordinates
    vec4 texColor = texture(particleTexture, gl_PointCoord);
    // Combine texture color with the interpolated particle color and fade by life ratio
    outFragColor = vec4(inColor.rgb, texColor.a*inColor.a);
}
