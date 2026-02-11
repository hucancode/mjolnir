# AGENTS.md
This file provides essential guidance for agentic coding assistants working with the project.

# Project Overview

Mjolnir is a 3D rendering engine written in Odin, using Vulkan for rendering

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
# run a single test called "test_name" inside "module_name"
odin test . --all-packages -define:ODIN_TEST_NAMES=module_name.test_name
# Check for compiler errors without building
make check
# Build all shaders
make shader
```

## Architecture Overview

### Core Engine Structure
The engine is organized into sub-systems with clear responsibility boundaries:

**Lower Level Systems (highly independent):**
- **GPU**: `mjolnir/gpu/` - Vulkan context, memory management, swapchain, pipeline helpers
- **Containers**: `mjolnir/containers/` - Generic data structures (handle pools, slab allocators)
- **Geometry**: `mjolnir/geometry/` - Camera, transforms, primitives, BVH, octree, AABB, frustum
- **Animation**: `mjolnir/animation/` - Skeletal animation support
- **Navigation**: `mjolnir/navigation/` - Recast + Detour integration
- **Physics**: `mjolnir/physics/` - Rigid body dynamics, collision detection, character controllers
- **Level Manager**: `mjolnir/level_manager/` - Async/blocking level transitions with loading screen support

**Higher Level Systems:**
- **Render**: Rendering sub-systems
  + Geometry Renderer
  + Lighting Renderer
  + Transparency Renderer
  + Particle Renderer
  + Post-process Renderer
  + Culling
- **World**: `mjolnir/world/` - Scene graph, GLTF loading

### Rendering Pipeline
The engine uses a deferred rendering with multiple passes:

1. **Visibility Pass** - Calculate visibility with frustum culling and occlusion culling, produce optimized draw lists and depth maps
2. **G-Buffer Pass** - Geometry data (position, normal, albedo, metallic/roughness, emissive)
3. **Lighting Pass** - Ambient + per-light additive rendering
4. **Particle Rendering** - GPU-based particle systems
5. **Post-Processing** - Effects like bloom, fog, cross-hatching, tone mapping

### Asset Support
- **GLTF Loading**: Support loading 3D models `mjolnir/world/gltf.odin`
- **OBJ Loading**: Support loading 3D models `mjolnir/world/obj.odin`
- **Navigation Meshes**: OBJ loading for navmesh geometry
- **Shader System**: GLSL shaders compiled to SPIR-V (in `mjolnir/shader/`)
  + vertex shader must be `shader.vert` and compiled to `vert.spv`
  + fragment shader must be `shader.frag` and compiled to `frag.spv`
  + compute shaders must be `*.comp` and compiled to `*.spv`

### GPU Resource Management
- Uses custom slab allocators and generational handle pools for efficient resource management
- Handle-based system for referencing resources safely with generation counters
- Resource warehouse pattern for centralized management
- **Bindless**: All GPU resources managed in array-based system. Draw commands send resource IDs to index into GPU arrays instead of raw data

## Development Notes

### Shader Development
- Shaders are in `mjolnir/shader/` organized by render pass
- Use `make shader` to rebuild all shaders. It's fast and incremental, you need not to build individual shader
- Compute shaders include:
  + Particle system: `compute.comp`, `compact.comp`, `emitter.comp`
  + Culling systems: `culling.comp` for visibility

### Common File Locations

- **Engine core**: `mjolnir/engine.odin` - Main engine loop with built-in camera controller
- **API**: `mjolnir/api.odin` - Public API for engine users (camera controls, level transitions)
- **GPU abstractions**: `mjolnir/gpu/` (context, memory, swapchain, pipeline helpers)
- **Containers**: `mjolnir/containers/` (handle pools, slab allocators)
- **Geometry systems**: `mjolnir/geometry/` (camera, transforms, BVH, octree, primitives)
- **Animation**: `mjolnir/animation/` (skeletal animation)
- **Navigation**: `mjolnir/navigation/` (Recast + Detour integration)
- **Physics**: `mjolnir/physics/` (rigid body, collision, character controllers)
- **Level Manager**: `mjolnir/level_manager/` (level transitions, loading screens)
- **World**: `mjolnir/world/` (scene graph, visibility, GLTF loading)
- **Shaders**: `mjolnir/shader/{shader_name}/`
- **Assets**: `assets/` (models, textures, etc.)
- **Tests**: `test_*.odin` - Unit tests
- **Examples**: `examples/` for end-to-end graphics tests (double as examples)

### Debugging Tips

- To debug visual issues, hardcode frame count limit in `engine.odin` `run` procedure to stop after few frames and examine logs
- To slow down the engine to avoid excessive logs. Set FPS in `engine.odin` to low value like 4 or 2.
- To capture visual result, run `make capture`, then analyze the newly created `screenshot.png`
- Graphics test runner: `examples/run.py` - Runs all graphics tests and compares against golden images

### Build Flags

- **REQUIRE_GEOMETRY_SHADER**: Compile with geometry shader support (required for spherical shadow mapping)
- **USE_PARALLEL_UPDATE**: Enable dedicated update thread for parallel scene updates
- **FRAME_LIMIT**: limit renderer to only render a few frames, useful for collecting logs from render procedure. without this logs would be super noisy
