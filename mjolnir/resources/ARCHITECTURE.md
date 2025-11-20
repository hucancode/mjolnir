# Resource Management Architecture

This document describes the architecture and patterns for the `mjolnir/resources` package.

## Overview

The resources package manages all engine resources using a handle-based system with reference counting and auto-purging. It follows a clear separation of concerns between orchestration (Manager), domain logic (individual resources), and GPU operations.

## Architecture Layers

```
┌─────────────────────────────────────────────────────┐
│            PUBLIC API (External Users)              │
│  - create_mesh(), create_material(), etc.          │
│  - Simple, high-level operations                   │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│         MANAGER (Orchestration Layer)               │
│  - Pool allocation/deallocation                     │
│  - Cross-resource coordination                      │
│  - Bulk operations (purge, shutdown)                │
│  - Bindless buffer lifecycle                        │
│  - Descriptor set management                        │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│      INDIVIDUAL RESOURCES (Domain Logic)            │
│  - Resource-specific initialization                 │
│  - Resource-specific cleanup                        │
│  - Data validation and transformation               │
│  - Internal state management                        │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│         GPU OPERATIONS (Low-level)                  │
│  - Buffer writes                                    │
│  - Descriptor updates                               │
│  - GPU resource creation/destruction                │
└─────────────────────────────────────────────────────┘
```

## Standardized Resource Patterns

All resources follow consistent naming patterns for their lifecycle operations:

### 1. Initialization Pattern

```odin
// Called AFTER pool allocation, BEFORE GPU upload
resource_init :: proc(self: ^Resource, ...) -> vk.Result
```

**Responsibilities:**
- ✅ Validate input data
- ✅ Allocate sub-resources (e.g., mesh allocates vertices/indices from slabs)
- ✅ Set up internal state
- ✅ Initialize resource-specific data structures
- ❌ DOES NOT write to bindless buffers (that's upload's job)
- ❌ DOES NOT allocate from pool (Manager does that before calling init)

**Examples:**
- `mesh_init` - Allocates vertices/indices from slabs, sets up skinning
- `material_init` - Sets material properties and texture handles
- `light_init` - Configures light type, color, radius, shadow casting
- `camera_init` - Creates render targets, depth pyramids, draw buffers

### 2. Upload Pattern

```odin
// Called AFTER init, uploads resource data to GPU bindless buffers
resource_upload_gpu_data :: proc(rm: ^Manager, handle: Handle, self: ^Resource) -> vk.Result
```

**Responsibilities:**
- ✅ Write resource data to bindless buffers at handle.index
- ✅ Update descriptor arrays if needed
- ✅ Ensure GPU state matches CPU state
- ❌ DOES NOT modify resource state (read-only on resource)

**Examples:**
- `mesh_upload_gpu_data` - Writes MeshData to mesh_data_buffer
- `material_upload_gpu_data` - Writes MaterialData to material_buffer
- `light_upload_gpu_data` - Writes LightData to lights_buffer
- `camera_upload_data` - Writes CameraData to camera_buffer

### 3. Cleanup Pattern

```odin
// Called BEFORE pool deallocation, releases sub-resources
resource_destroy :: proc(self: ^Resource, rm: ^Manager, ...)
```

**Responsibilities:**
- ✅ Free sub-allocated resources (vertices/indices from slabs, GPU images, etc.)
- ✅ Release resource-specific GPU resources
- ✅ Clean up internal data structures
- ✅ Decrement references to other resources (materials unref textures)
- ❌ DOES NOT free from pool (Manager does that after calling destroy)
- ❌ DOES NOT zero out bindless buffer data (unnecessary, pool handles reuse)

**Examples:**
- `mesh_destroy` - Frees vertices, indices, skinning data from slabs
- `material_destroy` - Unreferences all texture handles
- `texture_2d_destroy` - Destroys GPU image
- `camera_destroy` - Destroys render targets, depth pyramid, draw buffers
- `light_destroy` - Unregisters from active lights list

### 4. Update Pattern

```odin
// Called during runtime to update mutable resource data
resource_upload_data :: proc(rm: ^Manager, index: u32, frame_index: u32)
```

**Responsibilities:**
- ✅ Recalculate derived data (view matrices, frustum planes, etc.)
- ✅ Write updated data to GPU buffers
- ✅ Handle frame-dependent updates

**Examples:**
- `camera_upload_data` - Recalculates view/projection matrices, frustum planes
- `update_light_camera` - Updates light shadow camera transforms
- `update_light_gpu_data` - Refreshes light data in GPU buffer

## Creation Pattern

All resources follow this standardized creation pattern:

```odin
create_resource :: proc(
    gctx: ^gpu.GPUContext,
    rm: ^Manager,
    // ... resource-specific parameters ...
    auto_purge := false,
) -> (handle: Handle, ret: vk.Result) {
    // 1. Allocate from pool (Manager responsibility)
    resource: ^Resource
    handle, resource, ok := cont.alloc(&rm.resources)
    if !ok do return {}, .ERROR_OUT_OF_DEVICE_MEMORY

    // 2. Initialize resource-specific data (Resource responsibility)
    resource_init(resource, ...) or_return
    defer if ret != .SUCCESS do resource_destroy(resource, rm)

    // 3. Upload to GPU (Resource responsibility)
    resource.auto_purge = auto_purge
    resource_upload_gpu_data(rm, handle, resource) or_return

    return handle, .SUCCESS
}
```

**Benefits:**
1. Consistent error handling with cleanup
2. Clear separation of concerns
3. Proper resource cleanup on failure
4. Explicit auto_purge configuration

## Manager Responsibilities

### OWNS:
- All resource pools (`Pool(Mesh)`, `Pool(Material)`, etc.)
- All bindless GPU buffers (vertex, index, material, transform buffers)
- Global GPU resources (samplers, descriptor layouts, pipeline layouts)
- Tracking lists (`active_lights`, `animatable_sprites`)

### DOES:
- ✅ Pool allocation (`cont.alloc()` to get handles)
- ✅ Pool deallocation (`cont.free()` to release handles)
- ✅ System initialization (create all pools, buffers, descriptors)
- ✅ System shutdown (destroy all pools, buffers, release GPU resources)
- ✅ Cross-resource coordination (when mesh destroyed, update materials that reference it)
- ✅ Bulk operations (`purge_unused_resources()`, mass updates)
- ✅ Bindless buffer lifecycle (create/destroy GPU buffers)
- ✅ Descriptor management (create/update descriptor sets for bindless arrays)
- ✅ Reference tracking registration (add/remove from `active_lights`, etc.)

### DOES NOT:
- ❌ Know resource-specific initialization logic (mesh skinning, camera frustum, etc.)
- ❌ Perform individual resource GPU uploads (delegates to resource methods)
- ❌ Contain resource-specific business logic
- ❌ Directly manipulate individual resource data fields (accesses via methods)

## Reference Counting & Auto-Purging

Resources support automatic cleanup when no longer referenced:

### ResourceMetadata:
```odin
ResourceMetadata :: struct {
  ref_count:  u32,  // Reference count for resource lifetime tracking
  auto_purge: bool, // true = purge when ref_count==0, false = manual lifecycle
}
```

### Reference Counting:
- `resource_ref(rm, handle)` - Increment reference count
- `resource_unref(rm, handle) -> (ref_count: u32, ok: bool)` - Decrement reference count
- When `auto_purge == true && ref_count == 0`, resource is marked for purging

### Purging:
- `purge_unused_resources(rm, gctx)` - Scans all pools and frees unreferenced resources
- Currently O(n) scan - optimization TODO: use O(1) tracking with purgeable_resources list

## Resource Types

### Mesh
- **Init**: Allocates vertex/index/skinning data from slabs
- **Upload**: Writes MeshData to bindless buffer
- **Destroy**: Frees slab allocations, cleans up bones
- **Auto-purge**: Supported

### Material
- **Init**: Sets material properties (color, metallic, roughness, textures)
- **Upload**: Writes MaterialData to bindless buffer, updates texture indices
- **Destroy**: Unreferences all texture handles
- **Auto-purge**: Supported

### Texture (2D/Cube)
- **Init**: Handled by `gpu.image_create` (loads from file/data/pixels)
- **Upload**: Registers in bindless descriptor array
- **Destroy**: Destroys GPU image
- **Auto-purge**: Supported

### Light
- **Init**: Sets light type, color, radius, shadow settings
- **Upload**: Writes LightData to bindless buffer
- **Destroy**: Unregisters from active lights list
- **Auto-purge**: Not supported (managed by scene graph)

### Camera
- **Init**: Creates render targets (G-buffer, depth), depth pyramid, draw buffers
- **Upload**: Writes CameraData with view/projection/frustum to bindless buffer
- **Destroy**: Destroys all render targets and GPU resources
- **Auto-purge**: Not supported (managed by scene graph)

## File Organization

```
mjolnir/resources/
├── manager.odin          # Manager struct, init/shutdown, system-wide operations
├── constants.odin        # MAX_* limits, buffer sizes, configurations
├── tracking.odin         # Reference counting, purging operations
├── mesh.odin            # Mesh resource lifecycle
├── material.odin        # Material resource lifecycle
├── texture.odin         # Texture resource lifecycle (2D/Cube)
├── light.odin           # Light resource lifecycle
├── camera.odin          # Camera resource lifecycle
├── spherical_camera.odin # Spherical camera (for point light shadows)
├── node.odin            # Scene node GPU data upload
├── sprite.odin          # Sprite resource
├── emitter.odin         # Particle emitter resource
├── forcefield.odin      # Particle force field resource
├── clip.odin            # Animation clip resource
└── navigation.odin      # Navigation mesh resource
```

## Best Practices

### When Creating Resources:
1. Always use the `create_*` functions - don't manually allocate from pools
2. Set `auto_purge = true` for temporary/transient resources (loaded assets)
3. Set `auto_purge = false` for scene-managed resources (lights, cameras)
4. Handle errors properly - check return values

### When Destroying Resources:
1. Use `destroy_*` functions - they handle proper cleanup
2. Don't free from pool manually - let the destroy function handle it
3. Unreference dependencies before destroying (materials unref textures)

### When Adding New Resources:
1. Follow the standardized pattern: `_init`, `_upload_gpu_data`, `_destroy`
2. Add to appropriate pool in Manager
3. Add purge function if auto-purge is supported
4. Document responsibilities in this file

## Migration Notes

The refactoring standardized patterns across all resources:

**Before:**
- Inconsistent naming (`material_write_to_gpu` vs `mesh_upload_gpu_data`)
- Mixed concerns (Manager did resource-specific initialization)
- No explicit destroy functions for some resources
- Cleanup code duplicated in purge functions

**After:**
- Consistent naming: `_init`, `_upload_gpu_data`, `_destroy`
- Clear separation: Manager orchestrates, Resources implement
- All resources have destroy functions
- Cleanup reuses destroy functions

## Future Optimizations

1. **O(1) Purging**: Add `purgeable_resources: [dynamic]PurgeableResource` to Manager
   - Track resources when ref_count drops to 0
   - Avoid O(n) scans in `purge_unused_resources`

2. **Batch GPU Uploads**: Group multiple resource uploads into single buffer write
   - Reduce GPU driver overhead
   - Use staging buffer for large batches

3. **Resource Streaming**: Load resources asynchronously in background
   - Don't block rendering thread
   - Use double-buffered loading

4. **Resource Defragmentation**: Compact slab allocators periodically
   - Reduce fragmentation
   - Improve cache locality
