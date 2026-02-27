# Frame Graph Architecture Requirements

## Critical Use Cases (From Current Architecture)

### Frame-Offset Dependencies (Temporal Scoping)
Current pattern: Frame N compute writes buffers consumed by frame N+1 graphics
```odin
// Compute writes to NEXT frame's buffers for double-buffering
next_frame_index := (frame_index + 1) % FRAMES_IN_FLIGHT
depth_pyramid.build(&depth_pyramid_sys, cmd, depth, pyramid_textures[next_frame_index])
occlusion_culling.perform(&culling_sys, cmd, pyramid[next_frame_index], draw_commands[next_frame_index])

// Graphics reads from CURRENT frame's buffers (written by previous frame's compute)
geometry.render(cmd, draw_commands[frame_index], draw_count[frame_index])
```
**Frame graph must support**: Explicit frame offset in resource declarations

### Cross-Scope Dependencies
Lighting pass (PER_CAMERA) reads shadow maps from ALL lights (PER_LIGHT):
```odin
lighting_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    manager := cast(^Manager)user_data
    // Read ALL shadow maps from ALL light instances
    for light_idx in 0..<manager.num_lights {
        shadow_map, ok := find_texture_in_scope(setup.graph, "shadow_map", light_idx)
        if ok do read_texture(setup, shadow_map)
    }
}
```

### Runtime Instance Count
Number of cameras/lights unknown at graph build time - determined at runtime from world state:
```odin
// Graph must instantiate N passes where N is discovered dynamically
for &entry in world.cameras.entries {
    if !entry.active do continue
    // Create camera instance
}
```

### Conditional Passes Per Instance
Each camera has `enabled_passes` bit set - passes can be disabled per-camera:
```odin
Camera :: struct {
    enabled_passes: PassTypeSet,  // GEOMETRY | LIGHTING | PARTICLES etc
}
// Graph must skip disabled passes and remove their resources
```

### Async Compute Queue
Compute and graphics use separate command buffers submitted to different queues:
```odin
compute_cmd_buffer := has_async_compute ? compute_command_buffers[frame_index] : command_buffers[frame_index]
// Both recorded in parallel, submitted with semaphore sync
```
**Frame graph must support**: QueueType.COMPUTE vs QueueType.GRAPHICS passes

### Persistent External Resources
Resources that outlive the graph (created outside, registered for use inside):
```odin
// These exist before graph compilation
texture_manager: gpu.TextureManager      // Created in Manager.init()
mesh_manager: gpu.MeshManager
bone_buffer: gpu.PerFrameBindlessBuffer
// Graph must reference these without owning them
```

### Intra-Pass Barriers
Current system emits barriers WITHIN a pass (not just between passes):
```odin
record_transparency_pass :: proc(...) {
    // Mid-pass barrier after culling, before drawing
    gpu.buffer_barrier(cmd, draw_commands, .SHADER_WRITE, .INDIRECT_COMMAND_READ)
    vk.CmdDrawIndexedIndirect(cmd, draw_commands, ...)
}
```
**Frame graph must**: Either auto-infer these OR allow manual emission

## Core Principles

### Resource Ownership
- **Graph owns transient resources** (textures, buffers) - not external managers
- Graph handles allocation, aliasing, lifetime tracking
- Memory reuse: resources with non-overlapping lifetimes share memory
- **Per-frame variants**: Resources with frame offsets get FRAMES_IN_FLIGHT physical copies
  - `FRAMES_IN_FLIGHT` typically = 2 or 3 (double/triple buffering)
  - Example: `draw_commands` → `draw_commands[0]`, `draw_commands[1]`, `draw_commands[2]`
  - Frame offset determines which variant is used each frame

### Architectural Layers: Declaration vs Runtime

**DECLARATION LAYER** (graph building - templates):
```odin
// Pass template - describes instantiation strategy
PassDecl :: struct {
    name:    string,
    scope:   PassScope,   // GLOBAL, PER_CAMERA, PER_LIGHT
    queue:   QueueType,
    setup:   PassSetupProc,
    execute: PassExecuteProc,
}

// Abstract resource handle - NOT concrete allocation
ResourceId :: struct($T: typeid) {
    index:   u32,    // Index into resource declaration table
    version: u32,    // Validation generation counter
}
TextureId :: ResourceId(Texture)
BufferId  :: ResourceId(Buffer)

// Resource declaration - describes requirements
ResourceDecl :: struct {
    name:         string,
    type:         ResourceType,
    desc:         union { TextureDesc, BufferDesc },
    frame_offset: FrameOffset,
    scope_idx:    int,  // Which camera/light instance created this
}
```

**RUNTIME LAYER** (compiled graph - concrete instances):
```odin
// Concrete pass instance after instantiation
PassInstance :: struct {
    decl:           ^PassDecl,        // Back-reference to template
    instance_id:    u32,
    scope_idx:      int,              // Camera/light index
    enabled:        bool,
    resources:      map[string]ResourceInstanceId,
    dependencies:   []PassInstanceId,  // Incoming edges (DAG)
}

// Physical GPU resource after allocation
ResourceInstance :: struct {
    decl:           ^ResourceDecl,
    // Physical handles (union - only one is valid)
    physical: union {
        struct { buffer: vk.Buffer, size: vk.DeviceSize },
        struct { image: vk.Image, view: vk.ImageView, format: vk.Format },
    },
    memory:         vk.DeviceMemory,
    frame_variant:  int,  // Which FRAMES_IN_FLIGHT copy (0, 1, or 2)
}

// Graph struct contains ONLY compiled runtime data (no declaration layer)
Graph :: struct {
    pass_instances:     [dynamic]PassInstance,
    resource_instances: [dynamic]ResourceInstance,
    sorted_passes:      []PassInstanceId,  // Topological order
    barriers:           map[PassInstanceId][]Barrier,
}
```

**Compilation is a pure function**:
```odin
CompileContext :: struct {
    num_cameras:      int,
    num_lights:       int,
    frames_in_flight: int,
    gctx:             ^gpu.GPUContext,  // For allocation
}

// Takes declarations, produces runtime Graph
compile :: proc(
    pass_decls: []PassDecl,
    ctx: CompileContext,
) -> (graph: Graph, err: CompileError) {
    // 1. Instantiate passes (PER_CAMERA → N instances)
    // 2. Run setup callbacks to collect resource declarations
    // 3. Validate (cycles, dangling reads, type matching)
    // 4. Allocate physical resources
    // 5. Compute barriers
    // 6. Topological sort
    return graph, .Ok
}
```

**Key insight**: There is NO "Graph declaration struct" - only PassDecl[] goes in, Graph comes out.

### Two-Phase Pass Execution

**Setup Phase (CPU, graph building):**
```odin
geometry_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    // Look up resources created by previous passes
    depth_id, _ := find_texture(setup.graph, "depth_prepass")
    read_texture(setup, depth_id)

    // Create new resources (graph manages allocation)
    gbuffer := create_texture(setup, "gbuffer_albedo", gbuffer_desc)
    write_texture(setup, gbuffer)
}
```

**Execute Phase (GPU command recording):**
```odin
geometry_execute :: proc(res: ^PassResources, cmd: vk.CommandBuffer, user_data: rawptr) {
    // Resources already resolved by graph compiler
    depth_view := get_texture(res, "depth_prepass").view
    gbuffer_view := get_texture(res, "gbuffer_albedo").view
    vk.CmdBeginRendering(cmd, depth_view, gbuffer_view, ...)
}
```

### Automatic Graph Compilation
1. **Validation** (must fail if invalid):
   - **Dangling reads**: Every `read_*()` must have corresponding `create_*()` or `register_external_*()`
   - **Cyclic dependencies**: Graph must be acyclic (DAG)
   - **Frame offset consistency**: Resources with NEXT writes must also have CURRENT/PREV reads (buffer versioning)
   - **Type mismatches**: Texture reads must match texture creates (not buffer creates)
   - **Queue compatibility**: Compute passes can't write to render targets (graphics-only resources)
2. **Dependency resolution**: Read/write declarations build DAG automatically
   - **Within same frame**: Passes touching same resource with same offset create edges
   - **Frame offsets do NOT create edges**: NEXT write and CURRENT read touch different buffers (no edge)
   - **Temporal dependencies do NOT affect pass order**: Graphics reading from previous frame doesn't wait for current frame's compute
   - **Cross-scope reads**: Create edges between scoped passes (lighting → all shadow maps)
3. **Barrier insertion rules**:
   - **Same-frame dependencies**: Full barriers (execution + memory) between dependent passes
   - **Temporal dependencies**: Memory barriers only (no execution dependency)
     - Example: Frame N graphics reads buffer written by frame N-1 compute
     - No execution edge (N-1 already finished), but barrier ensures memory visibility
3. **Pass culling**: Remove passes whose outputs are never consumed
   - Respect conditional `enabled` flags per-instance
4. **Resource aliasing**: Reuse memory for non-overlapping lifetimes
   - External resources are NOT aliased (persistent)
5. **Barrier insertion**: Infer barriers from resource state transitions
   - Queue ownership transfers for async compute
   - Image layout transitions
6. **Execution order**: Topological sort of DAG (Kahn's algorithm detects cycles)

### Pass Instantiation
- Pass templates: `PER_CAMERA`, `PER_LIGHT`, `GLOBAL`
- **Runtime instance count**: Number of instances determined at graph build time (dynamic)
- Example: `shadow_pass(PER_LIGHT)` → N concrete passes where N = active lights with shadows
- **Each instance has isolated resource namespace** - prevents name collisions
- Resource names automatically scoped: `"depth_prepass"` → `"depth_prepass_cam_0"`, `"depth_prepass_cam_1"`
- **Conditional instantiation**: Passes can be disabled per-instance via enabled flags

## Graph Lifecycle

### Compile Once, Execute Many
Graph is compiled once (or when topology changes), then executed every frame:

```odin
// COMPILE PHASE (called once or when topology changes)
compile_graph :: proc(gctx: ^gpu.GPUContext, num_cameras: int, num_lights: int) -> (Graph, CompileError) {
    // Input: Pass declarations (templates)
    pass_decls := []PassDecl{
        depth_prepass_decl,
        geometry_decl,
        lighting_decl,
        // ... all pass templates
    }

    // Compile: PassDecl[] → Graph (runtime)
    ctx := CompileContext{
        num_cameras      = num_cameras,
        num_lights       = num_lights,
        frames_in_flight = FRAMES_IN_FLIGHT,
        gctx             = gctx,
    }

    graph := compile(pass_decls, ctx) or_return
    // Inside compile():
    // 1. Instantiate passes (PER_CAMERA × num_cameras)
    // 2. Run setup callbacks to collect ResourceDecl
    // 3. Validate (cycles, dangling reads)
    // 4. Allocate physical GPU resources (FRAMES_IN_FLIGHT variants)
    // 5. Compute barriers
    // 6. Topological sort

    return graph, .Ok
}

// EXECUTE PHASE (called every frame with different frame_index)
execute :: proc(graph: ^Graph, frame_index: u32, cmd: vk.CommandBuffer) {
    // Frame offsets resolve to physical resource variants at EXECUTE time
    for pass_id in graph.sorted_passes {
        pass := &graph.pass_instances[pass_id]

        // Resolve resources based on frame_index + frame_offset
        resources := resolve_pass_resources(graph, pass, frame_index)
        // resources.draw_commands → draw_commands[(frame_index+offset) % FRAMES_IN_FLIGHT]

        pass.decl.execute(resources, cmd, pass.user_data)
    }
}
```

**Key architecture**: `PassDecl[]` (declarations) → `compile()` → `Graph` (runtime) → `execute(frame_index)`

### Frame Offset = Buffer Versioning (NOT Graph Dependencies!)

**Critical insight**: Frame offsets do NOT create edges in the dependency graph. They specify **which buffer version** to use.

```odin
// Within SINGLE frame N's graph (no cycle!):
┌─────────────────────────────────────────────┐
│ Frame N execution (single graph):           │
│                                              │
│ Compute passes:                              │
│   write buffer[(N+1) % FRAMES_IN_FLIGHT]    │ ← "NEXT"
│                                              │
│ Graphics passes:                             │
│   read buffer[N % FRAMES_IN_FLIGHT]         │ ← "CURRENT"
│                                              │
│ No dependency edge between them!             │
│ (They touch different buffer versions)       │
└─────────────────────────────────────────────┘

// Temporal dependency (across frames):
Frame N-1 compute writes buffer[N]
  ↓ (time passes, frame N-1 finishes)
Frame N graphics reads buffer[N]
```

**The graph within a single frame is acyclic**:
- Compute and graphics in frame N don't depend on each other (different buffers)
- Graphics in frame N implicitly depends on compute from frame N-1 (temporal, not graph edge)

**Cold start problem** (Frame 0):
```odin
// Frame 0 graphics reads buffer[0], but nobody wrote it yet!
// Solutions:
// 1. Initialize buffer[0] to empty/defaults during graph compilation
// 2. Skip graphics passes on first frame
// 3. Run compute twice before first graphics (warm-up frame)
```

**FRAMES_IN_FLIGHT = 2 execution trace**:
```
Frame 0: compute writes buf[1], graphics reads buf[0] (uninitialized!)
Frame 1: compute writes buf[0], graphics reads buf[1] (from frame 0 compute)
Frame 2: compute writes buf[1], graphics reads buf[0] (from frame 1 compute)
Frame 3: compute writes buf[0], graphics reads buf[1] (from frame 2 compute)
...steady state, no cycles
```

### When to Rebuild Graph
Rebuild only when **topology changes**:
- Camera added/removed
- Light added/removed/shadow toggled
- Pass enabled/disabled
- Resource format/size changed

Most frames execute the same compiled graph with different `frame_index`.

## Compilation & Validation

### Graph Compilation Flow
```odin
compile :: proc(graph: ^Graph) -> CompileResult {
    // 1. Run all pass setup callbacks to declare resources
    for pass in graph.passes {
        pass.setup(&pass_setup, pass.user_data)
    }

    // 2. VALIDATE - fail fast on errors
    validate_no_dangling_reads(graph) or_return  // Error: read resource that doesn't exist
    validate_no_cycles(graph) or_return          // Error: cyclic dependency detected
    validate_type_matching(graph) or_return      // Error: type mismatch

    // 3. Optimize
    cull_unused_passes(graph)                    // Remove passes whose outputs aren't consumed

    // 4. Compile
    topological_sort(graph) or_return            // Determine execution order
    compute_resource_lifetimes(graph)            // Find first/last use of each resource
    allocate_and_alias_resources(graph)          // Assign physical memory
    compute_barriers(graph)                      // Insert state transitions

    return .Ok
}
```

### Validation Errors
```odin
CompileError :: enum {
    Ok,
    DanglingRead,    // Pass reads resource that was never created
    CyclicGraph,     // Pass A depends on B, B depends on A (cycle)
    TypeMismatch,    // Pass reads resource as wrong type (texture vs buffer)
    AliasingFailed,  // Not enough memory for resource aliasing
}
```

### Error Examples
```odin
// ERROR: Dangling read
geometry_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    depth, _ := find_texture(setup, "depth_prepass")
    read_texture(setup, depth)  // ERROR: No pass creates "depth_prepass"
}

// ERROR: Cyclic dependency
pass_a_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    b_output, _ := find_texture(setup, "b_output")
    read_texture(setup, b_output)  // A reads from B

    a_output := create_texture(setup, "a_output", desc)
    write_texture(setup, a_output)  // A writes a_output
}

pass_b_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    a_output, _ := find_texture(setup, "a_output")
    read_texture(setup, a_output)  // B reads from A → CYCLE!

    b_output := create_texture(setup, "b_output", desc)
    write_texture(setup, b_output)
}
// Cycle: A → B → A (compilation fails)
```

## Implementation Details

### Pass Declaration
```odin
PassSetupProc   :: proc(setup: ^PassSetup, user_data: rawptr)
PassExecuteProc :: proc(res: ^PassResources, cmd: vk.CommandBuffer, user_data: rawptr)

PassScope :: enum { GLOBAL, PER_CAMERA, PER_LIGHT }
QueueType :: enum { GRAPHICS, COMPUTE }

PassDecl :: struct {
    name:     string,
    scope:    PassScope,   // GLOBAL, PER_CAMERA, PER_LIGHT
    queue:    QueueType,   // GRAPHICS or COMPUTE (for async compute)
    setup:    PassSetupProc,
    execute:  PassExecuteProc,
    enabled:  bool,        // Can be disabled conditionally per-instance
}
```

### Resource API
```odin
PassSetup :: struct {
    graph:     ^Graph,
    pass_id:   PassId,
    scope_idx: int,  // Camera/light index for PER_CAMERA/PER_LIGHT passes, -1 for GLOBAL
    // NO frame_index - setup declares requirements, not execution!
}

FrameOffset :: enum i8 {
    CURRENT = 0,   // Read/write current frame's resource
    NEXT    = 1,   // Write to next frame (for compute→next frame graphics)
    PREV    = -1,  // Read from previous frame (rare, for temporal effects)
}

// Create transient resources - names auto-scoped by pass instance
create_texture :: proc(setup: ^PassSetup, name: string, desc: TextureDesc) -> TextureId
create_buffer  :: proc(setup: ^PassSetup, name: string, desc: BufferDesc) -> BufferId
// Creates "depth" in camera 0 → actual name: "depth_cam_0"
// Creates "depth" in camera 1 → actual name: "depth_cam_1"

// Register external resources (persistent resources created outside graph)
register_external_texture :: proc(setup: ^PassSetup, name: string, handle: vk.Image, view: vk.ImageView) -> TextureId
register_external_buffer  :: proc(setup: ^PassSetup, name: string, handle: vk.Buffer, size: vk.DeviceSize) -> BufferId
// For resources like swapchain, texture_manager.descriptor_set, mesh_manager buffers

// Find resources created by other passes
find_texture :: proc(setup: ^PassSetup, name: string) -> (TextureId, bool)
find_buffer  :: proc(setup: ^PassSetup, name: string) -> (BufferId, bool)
// In camera 0: find_texture("depth") → looks up "depth_cam_0" first
// Falls back to global "depth" if not found in scope

// Cross-scope lookup - explicitly reference other instances
find_texture_in_scope :: proc(graph: ^Graph, name: string, scope_idx: int) -> (TextureId, bool)
// Lighting pass reads all shadow maps: find_texture_in_scope("shadow_map", light_idx)

// Declare usage - builds dependency graph
// frame_offset: CURRENT (default), NEXT (compute writes for next frame), PREV (temporal reads)
read_texture  :: proc(setup: ^PassSetup, id: TextureId, frame_offset := FrameOffset.CURRENT)
write_texture :: proc(setup: ^PassSetup, id: TextureId, frame_offset := FrameOffset.CURRENT)
read_buffer   :: proc(setup: ^PassSetup, id: BufferId, frame_offset := FrameOffset.CURRENT)
write_buffer  :: proc(setup: ^PassSetup, id: BufferId, frame_offset := FrameOffset.CURRENT)
```

### Frame Offset Example (Temporal Dependencies)
```odin
// Frame N graph structure:
occlusion_culling_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    depth, _ := find_texture(setup, "depth_pyramid")
    read_texture(setup, depth, .CURRENT)

    draw_commands := create_buffer(setup, "visible_draw_commands", draw_cmd_desc)
    write_buffer(setup, draw_commands, .NEXT)  // Writes to buf[(N+1) % FRAMES_IN_FLIGHT]
}

geometry_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    draw_commands, _ := find_buffer(setup, "visible_draw_commands")
    read_buffer(setup, draw_commands, .CURRENT)  // Reads from buf[N % FRAMES_IN_FLIGHT]
}

// NO EDGE between occlusion_culling → geometry in frame N's graph!
// They touch different buffer versions (N+1 vs N)

// Execution in frame N:
// 1. occlusion_culling runs, writes buf[N+1]
// 2. geometry runs in PARALLEL (no dependency), reads buf[N]
//    ↑ buf[N] was written by frame N-1's occlusion_culling
// 3. Memory barrier emitted before geometry to ensure buf[N] writes are visible
//    (even though frame N-1 already finished)
```

**Key point**: Temporal read from previous frame needs memory barrier but NOT execution dependency!

### Resource Scoping Example
```odin
// Depth prepass (PER_CAMERA) - runs for camera 0 and camera 1
depth_prepass_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    // setup.scope_idx = 0 for camera 0, 1 for camera 1
    depth := create_texture(setup, "depth", depth_desc)
    // Camera 0: actual name = "depth_cam_0"
    // Camera 1: actual name = "depth_cam_1"
    write_texture(setup, depth)
}

// Geometry pass (PER_CAMERA) - runs for camera 0 and camera 1
geometry_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    // Lookup in same scope (automatic)
    depth, _ := find_texture(setup, "depth")
    // Camera 0: finds "depth_cam_0"
    // Camera 1: finds "depth_cam_1"
    read_texture(setup, depth)

    gbuffer := create_texture(setup, "gbuffer", gbuffer_desc)
    write_texture(setup, gbuffer)
}

// Lighting pass (PER_CAMERA) - reads shadow maps from ALL lights
lighting_setup :: proc(setup: ^PassSetup, user_data: rawptr) {
    manager := cast(^Manager)user_data

    // Read resources in same camera scope
    gbuffer, _ := find_texture(setup, "gbuffer")  // Scoped to this camera
    read_texture(setup, gbuffer)

    // Read resources from other scopes (all shadow maps)
    for light_idx in 0..<manager.num_lights {
        shadow_map, ok := find_texture_in_scope(setup.graph, "shadow_map", light_idx)
        if ok do read_texture(setup, shadow_map)
    }

    output := create_texture(setup, "final_color", color_desc)
    write_texture(setup, output)
}
```

### Pipeline Management
- Passes own their pipelines (stored in pass user_data context)
- Graph does NOT manage pipelines - separation of concerns
- Render context provides descriptor sets to passes

## Example Pass Types

### Compute Passes (QueueType.COMPUTE)
- `particle_simulation` - GLOBAL, writes particle_buffer (frame offset: NEXT)
- `shadow_culling` - PER_LIGHT, writes shadow_draw_commands (frame offset: NEXT)
- `depth_pyramid_build` - PER_CAMERA, reads depth, writes depth_pyramid (frame offset: NEXT)
- `occlusion_culling` - PER_CAMERA, reads depth_pyramid, writes visible_draw_commands (frame offset: NEXT)

### Graphics Passes (QueueType.GRAPHICS)
- `depth_prepass` - PER_CAMERA, writes depth_buffer
- `shadow_depth` - PER_LIGHT, reads shadow_draw_commands (frame offset: CURRENT = prev compute), writes shadow_map
- `geometry_pass` - PER_CAMERA, reads visible_draw_commands (frame offset: CURRENT), writes gbuffer
- `lighting_pass` - PER_CAMERA, reads gbuffer + shadow_maps (cross-scope from ALL lights), writes final_color
- `particle_render` - PER_CAMERA, reads particle_buffer (frame offset: CURRENT), writes final_color
- `transparency_pass` - PER_CAMERA, reads 5 draw command buffers, writes final_color
- `post_process` - GLOBAL, reads final_color, writes swapchain (external resource)
- `ui_pass` - GLOBAL, reads swapchain, writes swapchain

**Key patterns:**
- Compute passes write to NEXT frame, graphics passes read from CURRENT frame (double-buffering)
- Cross-scope dependencies: lighting (PER_CAMERA) reads shadow_maps from ALL lights (PER_LIGHT)
- External resources: swapchain registered but not created by graph
- No manual ordering needed - dependencies emerge from read/write declarations
