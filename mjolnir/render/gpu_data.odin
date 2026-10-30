package render

import "../geometry"


// The GPU data contract: the budgets, vertex formats, material and light types, effects and
// tables render writes and its shaders (in both backends) read.

// MAX_SLOTS is how many slots (SlotHandle) a scene has.
MAX_SLOTS :: 65536

// The views table holds every camera at CAMERA_VIEW_BASE + camera, then the shadow views.
@(private)
CAMERA_VIEW_BASE :: 0

@(private)
SHADOW_VIEW_BASE :: MAX_ACTIVE_CAMERAS

@(private)
MAX_VIEWS :: MAX_ACTIVE_CAMERAS + MAX_SHADOW_VIEWS

// MAX_SHADOW_MAPS is how many shadow-casting point and spot lights cast shadows at once; one
// directional light's cascades come on top.
MAX_SHADOW_MAPS :: 16

@(private)
SHADOW_MAP_SIZE :: 512

// a cube map renders six views, and a directional light's cascades come on top
@(private)
MAX_SHADOW_VIEWS :: MAX_SHADOW_MAPS * 6 + SHADOW_CASCADES

// MAX_PARTICLES is how many particles live at once, across every emitter.
MAX_PARTICLES :: 65536

// Debug line segments live in two rings of DEBUG_RING in the debug line table:
// [0] depth-tested, [1] drawn over the scene.
@(private)
MAX_SEGMENTS :: 65536

@(private)
DEBUG_RING :: MAX_SEGMENTS / 2

// OVERLAY_MAX_VERTICES and OVERLAY_MAX_INDICES are the overlay's capacity per frame.
@(private)
OVERLAY_MAX_VERTICES :: 65536

@(private)
OVERLAY_MAX_INDICES :: 98304

// Batches (Table.BATCHES): runs of nodes sharing a mesh and material, drawn by one indirect
// draw. Id 0 is none.
@(private)
MAX_BATCHES :: 4096

// TABLE_REGION_BYTES is the granularity of Renderer.dirty: bit r of a table's bits is its bytes
// [r * TABLE_REGION_BYTES, (r + 1) * TABLE_REGION_BYTES).
@(private)
TABLE_REGION_BYTES :: 4096

// HDR_COLOR_FORMAT is the format of the scene color target.
@(private)
HDR_COLOR_FORMAT :: TextureFormat.RGBA16F

// CameraImage names the images a camera renders into.
CameraImage :: enum {
  FINAL_IMAGE        = 0,
  NORMAL             = 1,
  ALBEDO             = 2,
  METALLIC_ROUGHNESS = 3,
  EMISSIVE           = 4,
  DEPTH              = 5,
  // how much ambient light reaches each pixel, 1 unoccluded (Camera.ambient_occlusion)
  AMBIENT_OCCLUSION  = 6,
  // the lit image before anti-aliasing (Camera.anti_aliasing) makes FINAL_IMAGE of it
  LIT                = 7,
}

// Each camera attachment's texture; pipelines drawing into an attachment take its format.
@(private)
CAMERA_IMAGES :: [CameraImage]TextureDesc {
  // written whole by the anti-aliasing pass
  .FINAL_IMAGE        = {format = HDR_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLED}},
  .NORMAL             = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  .ALBEDO             = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  .METALLIC_ROUGHNESS = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  // HDR, feeds bloom
  .EMISSIVE           = {format = .RGBA16F, usage = {.COLOR_TARGET, .SAMPLED}},
  // the depth pyramid build reads it
  .DEPTH              = {format = .D32F, usage = {.DEPTH_TARGET, .SAMPLED}, shared = true},
  // written by the ambient occlusion dispatch; RGBA8 is a storage format WebGPU can filter
  .AMBIENT_OCCLUSION  = {format = .RGBA8_UNORM, usage = {.SAMPLED, .STORAGE}},
  // written whole by the lighting dispatch, then drawn over by the forward pass
  .LIT                = {format = HDR_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLED, .STORAGE}},
}

// How a material is drawn, in this order. PBR is opaque: lit, occlusion-culled and casting
// shadows. The rest are drawn forward, alpha-blended over the lit image. material_shader_create
// adds types past these: your shaders.
MaterialType :: enum u32 {
  PBR,
  TRANSPARENT,
  WIREFRAME,
  RANDOM_COLOR,
  // camera-facing billboard showing one cell of the albedo sprite sheet, unlit; a negative scale
  // mirrors it, pixels under half alpha are cut out and depth orders overlapping sprites
  SPRITE,
}

@(private)
FIRST_FORWARD_TYPE :: MaterialType.TRANSPARENT

// LightType selects how a Light shines. The environment's light is Renderer.ibl_intensity.
LightType :: enum u32 {
  POINT,
  SPOT,
  // a sun: parallel rays along -Z, no falloff
  DIRECTIONAL,
}

// Vertex2D is one vertex of the 2D overlay.
Vertex2D :: geometry.Vertex2D

// OverlayBatch is a run of overlay indices drawn with one texture inside one scissor (x, y, w, h).
@(private)
OverlayBatch :: struct {
  first_index: u32,
  index_count: u32,
  scissor:     [4]i32,
  texture:     TextureHandle,
}

// The tables render writes, one copy per frame in flight (table); their sizes are given at
// init. The entries' layouts are render's, mirrored by the shaders.
@(private)
Table :: enum {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  EMITTERS,
  FORCE_FIELDS,
  LIGHTS,
  DEBUG_LINES,
  // draw batches and each node's batch: kept only where draws are not compacted by
  // multi-draw (Caps.multi_draw_indirect_count false); empty elsewhere
  BATCHES,
  NODE_BATCH,
  // per skinned vertex, the slot whose range holds it + 1; 0 is free (pass_skin.odin)
  SKIN_OWNERS,
  // where each light, emitter and force field is attached: a resource handle and a slot
  LIGHT_PLACEMENTS,
  EMITTER_PLACEMENTS,
  FORCE_FIELD_PLACEMENTS,
}

// SkinnedVertex is a vertex the skinning pass wrote, read by vertex shaders in place of the
// mesh's for a skinned node. w of position and normal is unused.
@(private)
SkinnedVertex :: struct {
  position: [4]f32,
  normal:   [4]f32,
  tangent:  [4]f32,
}

// One buffer per stream, sub-allocated by render; skinning is read through the scene set.
@(private)
MeshStream :: enum {
  VERTEX,
  INDEX,
  SKINNING,
}

// MeshData is a mesh as the cull shader reads it from the mesh table.
@(private)
MeshData :: struct {
  aabb_min:        [3]f32,
  index_count:     u32,
  aabb_max:        [3]f32,
  first_index:     u32,
  vertex_offset:   i32,
  skinning_offset: u32,
  flags:           MeshFlagSet,
  vertex_count:    u32,
}

@(private)
MeshFlag :: enum u32 {
  SKINNED,
}

@(private)
MeshFlagSet :: bit_set[MeshFlag;u32]

// GrayscaleEffect desaturates the image: luminance from weights, mixed in by strength.
GrayscaleEffect :: struct {
  weights:  [3]f32, // zero = Rec. 601 luma
  strength: f32,
}

// ToneMapEffect maps HDR color to display range with an exposure and gamma.
ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

// BlurEffect blurs the image in two separable passes.
BlurEffect :: struct {
  radius:         f32,
  weight_falloff: f32, // 0.0 = box blur, 1.0 = gaussian blur
}

// BloomEffect adds a blurred copy of the pixels above threshold.
BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
}

// OutlineEffect draws edges found in the normal and depth images.
OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

// FogEffect blends toward color between view depth start and end. Above height (world y) it
// thins by exp(-height_falloff * the distance above), averaged along the view ray; a
// height_falloff of 0 keeps it even.
FogEffect :: struct {
  color:          [3]f32,
  start:          f32,
  end:            f32,
  height:         f32,
  height_falloff: f32,
}

// CrossHatchEffect hatches pixels darker than lum_thresholds[i] (tonemapped luminance) with
// stroke family i: the two diagonals, then both shifted by hatch_offset_y.
CrossHatchEffect :: struct {
  hatch_offset_y: f32,
  lum_thresholds: [4]f32,
}

// DoFEffect blurs pixels away from the focus plane.
DoFEffect :: struct {
  focus_distance:  f32, // Distance to the focus plane
  focus_range:     f32, // Range where objects are in focus
  blur_strength:   f32, // Maximum blur radius
  bokeh_intensity: f32, // Bokeh effect intensity
}

@(private)
ParticleSystemParams :: struct {
  // rows of the emitter and force field placement tables
  emitter_placement_count:    u32,
  force_field_placement_count: u32,
  delta_time:       f32,
  frame_counter:    u32,
  // new particles this frame, all emitters together
  emit_total:       u32,
  // ring slot of the frame's first new particle
  emit_cursor:      u32,
}
