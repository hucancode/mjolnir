// glTF import, the glue between render, animation and world. load instantiates a whole .glb
// held in memory: render resources for its meshes, one animation rig per skin and one world
// node per glTF node. load_meshes and load_rig do one part each, for an application that
// builds its own scene from the parsed file.
// It reads no files: #load the .glb, or platform.read_file it.
package gltf
