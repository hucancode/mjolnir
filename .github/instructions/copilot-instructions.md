# AGENTS.md

This file provides essential guidance for agentic coding assistants working with the Mjolnir 3D rendering engine.

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
**Main Entry Point**: `main.odin` - Application setup and game loop

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
- **Particle System**: GPU compute-based particles with compaction optimization
  + Emitter system, physics simulation, visibility culling
- **Navigation**: Recast + Detour integration for pathfinding and navmesh
- **Geometry Systems**: BVH, octree, frustum culling, AABB calculations

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
  + Compute shaders: particle physics, compaction, visibility culling, scene culling, multi-camera culling

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
- Use `make shader` to rebuild all shaders before first build
- Individual shaders: `make mjolnir/shader/{shader_name}/vert.spv` (or frag.spv)
- Compute shaders include:
  + Particle system: `compute.comp`, `compact.comp`, `emitter.comp`
  + Culling systems: `culling.comp` for visibility, scene, and multi-camera culling

### Testing
- Tests are in `test/` directory
- Run with `make test`
- IMPORTANT: Don't try to recover a bad input or add safe guard to hide bad input, crash immediately so we know where to fix
- IMPORTANT: When you write tests, write 3 kinds of test - unit test and integration test and end-to-end test. In unit test, you provide the procedure with hard-coded perfect input. In integration test, you provide the procedure with inputs generated from its expected previous step in the pipeline. In end-to-end test, you provide the system with hard-coded user input from the start of the pipeline, let the system run, then check the final outputs.
- IMPORTANT: if a test need a setup phase, all test pre-conditions must be fulfilled before performing test. otherwise the test result is void, it does not guarantee the correctness of the function
- Most test must be run with a timeout of 30s using testing.set_fail_timeout(t, 30 * time.Second), some exception can be made with test working with big data
- When you fix a bug, don't try to disable the test, or add a guarding layer to hide the test. Instead, ultrathink to find the root cause of the bug and fix it properly
- Test each function in complete isolation
- Provide perfect, hard-coded inputs that test specific behaviors
- Verify outputs match expected results exactly (allowing for floating-point precision issues when applicable)
- Cover all code paths including error cases
- Each unit test must confirm a single aspect of functionality
- Avoid duplicate tests - each test should have a unique purpose
- Name tests descriptively: test_function_name_specific_scenario
- Do more thorough tests, do less trivial tests. Here are some of trivial tests:
 - just checking "something > 0" instead of strict value correctness
 - only test the object creation, destruction and no business logic
 - only test with empty input, then expect empty output
 - only test with trivially small input, then expect empty or small output
- Test edge cases (border values, empty value, invalid values)
- Test normal inputs (popular inputs normally seen in most use case)
- Unit tests verify individual functions in isolation with controlled inputs
- Integration tests validate interactions between multiple components
- System tests simulate real user workflows end-to-end
- write test that shows all the algorithm's behavior. all use case must be covered. don't only write tests that produce empty result or lacking diversity in result
- an unit test must confirm a single aspect of the feature. unit test must not be duplicated
- tests must not overdo works supposed to be in the main code. tests only call the function of interest and check the results

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
- **Utilities**: `mjolnir/interval_tree/` (specialized data structures)

### Debugging Tips

- Color blind consideration: Avoid using red/green color distinctions for debugging (developer has protan color blindness)
- To debug visual issues, hardcode frame count limit in `engine.odin` `run` procedure to stop after few frames and examine logs

# Odin Language Features Used

variable declaration
```odin
a: int = 42
b: int = 43
c: int = a + b
d := a + b + c // type can be inferred
e := 12 + 13 // type can be inferred
f := [4]f32{ 1.0, 2.0, 3.0, 4.0 } // type can be inferred
```
Array swizzling
```odin
speed: [3]f32
log.info("speed 2d", speed.xy)
log.info("speed 3d", speed.xyz)
color: [4]f32
log.info("color rgb", color.rgb)
log.info("color rgba", color.rgba)
```
return values propagation
```odin
do_a :: proc() -> vk.Result {
    log.info("do_a")
    return .SUCCESS
}
do_b :: proc() -> vk.Result {
    log.info("do_b")
    return .ERROR_UNKNOWN
}
do_all :: proc() -> vk.Result {
    do_a() or_return
    do_b() or_return
    return .SUCCESS
}
```
code access
```odin
// my_folder/my_file.odin
my_function :: proc() {
    log.info("my_function")
}
MyStruct :: struct {
    my_field: int,
}
// my_folder/my_other_file.odin
my_other_function :: proc() {
    log.info("my_other_function")
    my_function() // we can access the function in the same folder without doing anything special
    x : MyStruct // we can access the struct in the same folder without doing anything special
    log.info("my_field", x.my_field)
}
```
package declaration must be at the top of the file

slice pointer access
```odin
my_function :: proc(n: int, ptr: ^int) {
    log.info("this function require a size and a pointer to an int")
}
my_slice := [4]int{ 1, 2, 3, 4 }
my_function(len(my_slice), raw_data(my_slice)) // use raw_data to get a pointer to the slice data
```
procedure parameters are passed by immutable reference by default
```odin
MyStruct :: struct {
    a: i32,
    b: i32,
    c: f32,
    d: f32,
}
my_function :: proc(my_data: MyStruct) {
    log.info("my_function", my_data.a, my_data.b, my_data.c, my_data.d)
    // my_data.a = 42 // this will not compile, my_data is immutable
    my_mutable_data := my_data // this will compile, my_mutable_data is a mutable copy of my_data
    my_mutable_data.a = 42 // this will compile, but we are modifying a copy, not the original data
}
my_function2 :: proc(my_data: ^MyStruct) {
    log.info("my_function", my_data.a, my_data.b, my_data.c, my_data.d)
    my_data.a = 42 // this will compile and modify the original data
}
```
ranges and loops
```odin
// use exclusive range
for i in 0..<len(my_slice) {
    log.info("my_slice[%d] = %d", i, my_slice[i])
}
// use inclusive range
for i in 0..=len(my_slice)-1 {
    log.info("my_slice[%d] = %d", i, my_slice[i])
}
// iterate with value and index
for v,i in my_slice {
    log.infof("my_slice[%d] = %d", i, v)
}
// iterate values only
for v in my_slice {
    log.infof("v = %d", v)
}
// use `do` keyword for single statement
for v in my_slice do log.infof("v = %d", v)
if a > b do log.info("a is greater than b")
```
slice types
```odin
// dynamic slice can be append after creation
my_slice := make([dynamic]f32, 0)
defer delete(my_slice)
append(&my_slice, 10.0)
// fixed slice with runtime size
my_slice_fixed := make([]f32, 1)
defer delete(my_slice_fixed)
my_slice_fixed[0] = 10.0
// static array with compile-time size (fastest)
my_array := [1]f32{10.0}
```
