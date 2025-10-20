
# AGENTS.md
As a human, you may find this document verbose but that verbosity is intentional, you should read README.md instead.
This file provides essential guidance for agentic coding assistants working with the project.

# Project Overview

Mjolnir is a minimalistic 3D rendering engine written in Odin, using Vulkan for graphics rendering. It implements a deferred rendering pipeline with features like PBR (Physically Based Rendering), particle systems, shadow mapping, and post-processing effects.

## Build Commands

```bash
# Build and run in release mode
make run
# Build and run in debug mode
make debug
# Build only (release mode)
make build
# Build only (debug mode)
make build-debug
# Run tests
make test
# run a single test called "name"
odin test test -out:bin/test -define:ODIN_TEST_NAMES=tests.name
# Check for compiler errors without building
make check
# Build all shaders (required before first build)
make shader
# Build single shader
make mjolnir/shader/{shader_name}/vert.spv # build a specific vertex shader, use frag.spv for fragment shader
```

## Architecture Overview

### Core Engine Structure
The engine is organized into sub-systems with clear responsibility boundaries:

**Lower Level Systems (highly independent):**
- **GPU**: `mjolnir/gpu/` - Vulkan context, memory management, swapchain
- **Geometry**: `mjolnir/geometry/` - Camera, transforms, primitives, BVH, octree, AABB, frustum
- **Animation**: `mjolnir/animation/` - Skeletal animation support
- **Navigation**: `mjolnir/navigation/` - Recast + Detour integration

**Higher Level Systems:**
- **Resources**: `mjolnir/resources/` - Data management (Mesh, Material, Node, Skin, Light, Camera, etc.)
  + Handle-based system with generational arrays and slab allocators
- **Render**: Rendering sub-systems that depend on Resources
  + Shadow Renderer
  + Geometry Renderer
  + Lighting Renderer
  + Transparency Renderer
  + Particle Renderer
  + Post-process Renderer
- **World**: `mjolnir/world/` - Scene graph, visibility management, GLTF loading
  + Depends on Resources for data access

### Rendering Pipeline
The engine uses a deferred rendering approach with multiple passes:

1. **Depth Pre-pass** - Early depth testing for performance
2. **Shadow Pass** - Shadow map generation for point, directional, and spot lights
3. **G-Buffer Pass** - Geometry data (position, normal, albedo, metallic/roughness, emissive)
4. **Lighting Pass** - Ambient + per-light additive rendering
5. **Particle Rendering** - GPU-based particle systems
6. **Post-Processing** - Effects like bloom, fog, cross-hatching, tone mapping

### Key Systems
- **World Management**: `mjolnir/world/` - Scene graph, visibility culling, GLTF integration
- **Resource Management**: `mjolnir/resources/` - Handle-based system with generational arrays
  + Materials, Meshes, Nodes, Lights, Cameras, Emitters
  + Slab allocators for efficient memory management
- **Particle System**: Emitter system, physics simulation, visibility culling
- **Navigation**: Recast + Detour integration for pathfinding and navmesh
- **Geometry Systems**: BVH, octree, interval tree, frustum culling, AABB calculations

### Performance Features
- **GPU Culling**: GPU-based visibility culling
- **Parallel Scene Updates**: Dedicated update thread (compile flag: `USE_PARALLEL_UPDATE`)
- **Particle Compaction**: GPU compute reduces draw calls from MAX_PARTICLES (65K) to actual alive count
- **Indirect Rendering**: Uses `vk.CmdDrawIndirect` for efficient GPU-driven rendering

### Asset Support
- **GLTF Loading**: Full support for loading 3D models via `mjolnir/world/gltf.odin`
- **Texture Loading**: Various formats supported
- **Navigation Meshes**: OBJ loading for navmesh geometry
- **Shader System**: GLSL shaders compiled to SPIR-V (in `mjolnir/shader/`)
  + vertex shader must be `shader.vert` and compiled to `vert.spv`
  + fragment shader must be `shader.frag` and compiled to `frag.spv`
  + compute shaders must be `*.comp` and compiled to `*.spv`
  + Available shader passes: gbuffer, shadow, lighting, lighting_ambient, transparent, particle, postprocess, wireframe, navmesh, navmesh_debug, microui
  + Post-processing effects: bloom, blur, crosshatch, dof, fog, grayscale, outline, tonemap
  + Compute shaders: particle physics, compaction, visibility culling, scene culling

### GPU Resource Management
- Uses custom slab allocators and generational arrays for efficient resource management
- Handle-based system for referencing resources safely
- Resource warehouse pattern for centralized management
- **Bindless Approach**: All GPU resources managed in array-based system. Draw commands send resource IDs to index into GPU arrays instead of raw data
- **Staging Buffers**: Accumulate changes during update phase, flush to GPU buffers at frame start. Batch resource modifications through staging system to minimize GPU transfers

## Development Notes

### Code Style
- Minimal comments except for complex mathematical formulas
- Variable naming:
  + Long names for wide scope variables
  + Short names for narrow scope (i,j,k for counters, u,v,x,y,z for coordinates, r,g,b for colors)
- Use meaningful variable names instead of comments for clarity
- We use right handed Y up coordinate system
- Avoid thin wrapper functions, especially getters and setters that does nothing but get/set the variable
- Don't introduce unnecessary indirections, extra structs

### Shader Development
- Shaders are in `mjolnir/shader/` organized by render pass
- Use `make shader` to rebuild all shaders. It's fast and incremental, you need not to build individual shader
- Compute shaders include:
  + Particle system: `compute.comp`, `compact.comp`, `emitter.comp`
  + Culling systems: `culling.comp` for visibility

### Testing
**Philosophy**: Crash immediately on bad input - don't hide bugs with guards or workarounds. Fix root causes.

**Test Types** (write all three):
- **Unit**: Isolated functions with hard-coded perfect inputs
- **Integration**: Components working together with pipeline-generated inputs
- **End-to-End**: Full user workflow from start to final output

**Requirements**:
- Test in complete isolation with hard-coded inputs that verify specific behaviors
- Each test confirms ONE aspect of functionality (no duplicates)
- Verify exact outputs (allow floating-point precision tolerance)
- Use 30s timeout: `testing.set_fail_timeout(t, 30 * time.Second)`
- Fulfill all pre-conditions before testing
- Cover edge cases (boundaries, empty, invalid) AND normal cases

**Avoid Trivial Tests**:
- Only checking "something > 0" instead of exact values
- Only testing creation/destruction without business logic
- Only empty inputs producing empty outputs
- Lacking diversity in test cases

**Anti-patterns**:
- Don't disable tests to get more passing rates
- Don't add guards and babysitter to hide failing tests
- Don't duplicate production code logic in tests - just call and verify, no implementation should exist in tests.

### Common File Locations

- **Engine core**: `mjolnir/engine.odin`
- **GPU abstractions**: `mjolnir/gpu/` (context, memory, swapchain)
- **Geometry systems**: `mjolnir/geometry/` (camera, transforms, BVH, octree, primitives)
- **Animation**: `mjolnir/animation/` (skeletal animation)
- **Navigation**: `mjolnir/navigation/` (Recast + Detour integration)
- **Resources**: `mjolnir/resources/` (handles, materials, meshes, nodes, lights, cameras)
- **World**: `mjolnir/world/` (scene graph, visibility, GLTF loading)
- **Rendering**: Various renderer implementations
- **Shaders**: `mjolnir/shader/{pass_name}/`
- **Assets**: `assets/` (models, textures, etc.)
- **Tests**: `test/`

### Debugging Tips

- Color blind consideration: Avoid using red/green color distinctions for debugging (developer has protan color blindness)
- To debug visual issues, hardcode frame count limit in `engine.odin` `run` procedure to stop after few frames and examine logs
- To slow down the engine to avoid excessive logs. Set FPS in `engine.odin` to low value like 4 or 2.
- To capture visual result, run `make capture`, then analyze the newly created `screenshot.png`

# Odin Language Quick Reference

**Notes**: `odin check` only works on root project directory. `context` is a reserved keyword. Package declaration must be at the top of files.

```odin
// Variable declaration & inference
a: int = 42
b := a + 10  // type inferred
arr := [4]f32{1.0, 2.0, 3.0, 4.0}

// Array swizzling
speed: [3]f32
speed.xy  // 2D access
color: [4]f32
color.rgb  // RGB access

// Error propagation
do_all :: proc() -> vk.Result {
    do_a() or_return  // propagates errors
    do_b() or_return
    return .SUCCESS
}

// Same-folder access (no imports needed)
// Functions and types in same folder are automatically accessible

// Slice to pointer
my_slice := [4]int{1, 2, 3, 4}
my_function(len(my_slice), raw_data(my_slice))

// Parameters (immutable by default, pass ^T to modify)
my_function :: proc(data: MyStruct) {
    // data.a = 42  // ERROR: immutable
}
my_function2 :: proc(data: ^MyStruct) {
    data.a = 42  // OK: modifies original
}

// Loops & ranges
for i in 0..<len(arr) {}        // exclusive
for i in 0..=len(arr)-1 {}      // inclusive
for v, i in arr {}              // value + index
for v in arr {}                 // value only
for v in arr do log.info(v)     // single statement

// Slice types
dynamic := make([dynamic]f32, 0)  // growable
defer delete(dynamic)
fixed := make([]f32, 10)          // runtime size
defer delete(fixed)
static := [10]f32{}               // compile-time (fastest)
```
