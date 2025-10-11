#version 450

// Depth-only fragment shader for occlusion culling depth prepass
// No outputs needed - depth is automatically written from gl_Position.z

void main() {
    // Empty fragment shader - depth is written automatically by fixed-function pipeline
    // from the gl_Position.z value computed in the vertex shader
}
