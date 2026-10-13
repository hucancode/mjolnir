// Package gltf_render imports glTF meshes, materials and textures into render resources.
// Entry point: load_meshes, which returns one Maybe(render.MeshAttachment) per glTF mesh.
// Internals (texture, material and geometry loaders) live in gltf.odin.
package gltf_render
