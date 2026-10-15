package rhi

MAX_NODES_IN_SCENE :: 65536

MAX_ACTIVE_CAMERAS :: 128

// The views table holds every camera at CAMERA_VIEW_BASE + camera, then the shadow views.
CAMERA_VIEW_BASE :: 0

SHADOW_VIEW_BASE :: MAX_ACTIVE_CAMERAS

MAX_VIEWS :: MAX_ACTIVE_CAMERAS + MAX_SHADOW_VIEWS

MAX_SHADOW_MAPS :: 16

SHADOW_MAP_SIZE :: 512

// a cube map renders six views
MAX_SHADOW_VIEWS :: MAX_SHADOW_MAPS * 6

MAX_PARTICLES :: 65536

// mips of the prefiltered environment cube
PREFILTER_MIPS :: 5

// Debug line segments live in two rings of DEBUG_RING in the debug line table:
// [0] depth-tested, [1] drawn over the scene.
MAX_SEGMENTS :: 65536

DEBUG_RING :: MAX_SEGMENTS / 2

// UI_MAX_VERTICES and UI_MAX_INDICES are the overlay's capacity per frame.
UI_MAX_VERTICES :: 65536

UI_MAX_INDICES :: 98304

MAX_TEXTURES :: 1000

// Batches (Table.BATCHES): runs of nodes sharing a mesh and material, drawn by one indirect
// draw. Id 0 is none.
MAX_BATCHES :: 4096

// TABLE_REGIONS is the granularity of FrameDesc.dirty: region r of a table of n bytes is
// bytes [r * size, (r + 1) * size), size = ceil(n / TABLE_REGIONS).
TABLE_REGIONS :: 64

// A handle is the index of its texture in the bindless texture array; 0 is none.
TextureHandle :: distinct u32

// TextureFormat is the texel format of a texture. A8 is coverage, sampled as white with
// alpha = coverage.
TextureFormat :: enum {
  RGBA8_SRGB,
  RGBA8_UNORM,
  RGBA16F,
  RGBA32F,
  R32F,
  A8,
  D32F,
}

TextureUsage :: enum {
  SAMPLED,
  COLOR_TARGET,
  DEPTH_TARGET,
  STORAGE,
}

// TextureDesc describes a texture: `mip_levels` levels, six layers when `cube`. `shared`
// textures are also accessed by the async compute queue.
TextureDesc :: struct {
  extent:     [2]u32,
  format:     TextureFormat,
  usage:      bit_set[TextureUsage],
  mip_levels: u32,
  cube:       bool,
  shared:     bool,
}

// HDR_COLOR_FORMAT is the format of the scene color target.
HDR_COLOR_FORMAT :: TextureFormat.RGBA16F

// AttachmentType names the images a camera renders into.
AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  NORMAL             = 1,
  ALBEDO             = 2,
  METALLIC_ROUGHNESS = 3,
  EMISSIVE           = 4,
  DEPTH              = 5,
}

// Each camera attachment's texture; pipelines drawing into an attachment take its format.
ATTACHMENTS :: [AttachmentType]TextureDesc {
  .FINAL_IMAGE        = {format = HDR_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLED}},
  .NORMAL             = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  .ALBEDO             = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  .METALLIC_ROUGHNESS = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  // HDR, feeds bloom
  .EMISSIVE           = {format = .RGBA16F, usage = {.COLOR_TARGET, .SAMPLED}},
  // the depth pyramid build reads it
  .DEPTH              = {format = .D32F, usage = {.DEPTH_TARGET, .SAMPLED}, shared = true},
}

// How a material is drawn: one pipeline and, per camera, one indirect draw list per type,
// drawn in this order. The types before FIRST_FORWARD_TYPE are opaque: drawn into the
// G-buffer, lit by the lighting pass, tested against the depth pyramid and drawn into
// shadow maps. The rest are drawn forward, alpha-blended over the lit image.
MaterialType :: enum u32 {
  PBR,
  TRANSPARENT,
  WIREFRAME,
  RANDOM_COLOR,
  // camera-facing billboard showing one cell of the albedo sprite sheet
  SPRITE,
}

FIRST_FORWARD_TYPE :: MaterialType.TRANSPARENT

// LightType selects the light branch of the lighting shaders.
// AMBIENT is the environment light (image-based lighting, emissive, skybox), one per frame.
LightType :: enum u16 {
  POINT,
  SPOT,
  DIRECTIONAL,
  AMBIENT,
}

// Vertex is the mesh vertex format.
Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  tangent:  [4]f32, // xyz = tangent, w = handedness (for bitangent reconstruction)
}

// Vertex2D is one vertex of the 2D overlay.
Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
}

// UIBatch is a run of overlay indices drawn with one texture inside one scissor (x, y, w, h).
UIBatch :: struct {
  first_index: u32,
  index_count: u32,
  scissor:     [4]i32,
  texture:     TextureHandle,
}

// The tables render writes, one copy per frame in flight (table); their sizes are given at
// init. The entries' layouts are render's, mirrored by the shaders.
Table :: enum {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  EMITTERS,
  FORCEFIELDS,
  LIGHTS,
  DEBUG_LINES,
  // draw batches and each node's batch: kept only where draws are not compacted by
  // multi-draw (Caps.multi_draw_indirect_count false); empty elsewhere
  BATCHES,
  NODE_BATCH,
}

// One buffer per stream, sub-allocated by render; skinning is read through the scene set.
MeshStream :: enum {
  VERTEX,
  INDEX,
  SKINNING,
}

// MeshData is a mesh as the cull shader reads it from the mesh table.
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

MeshFlag :: enum u32 {
  SKINNED,
}

MeshFlagSet :: bit_set[MeshFlag;u32]

// GrayscaleEffect desaturates the image. Effect structs are pushed verbatim, so their layout
// must match each shader's push block.
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

// FogEffect blends toward color between depth start and end.
FogEffect :: struct {
  color: [3]f32,
  start: f32,
  end:   f32,
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

// PostprocessEffect is one entry of the effect stack; nil copies the input to the output unchanged.
PostprocessEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
  FogEffect,
  CrossHatchEffect,
  DoFEffect,
}

// PostPass is one fullscreen pass of the effect stack: pass `pass` of effect (blur and bloom
// take two) reads input, the previous pass's output, and original, the previous pass's input,
// and writes output; NO_TEXTURE (0) is the presented image. A nil effect copies input.
PostPass :: struct {
  effect:                   PostprocessEffect,
  pass:                     u32,
  input, original, output:  TextureHandle,
}

ParticleSystemParams :: struct {
  emitter_count:    u32,
  forcefield_count: u32,
  delta_time:       f32,
  frame_counter:    u32,
  // new particles this frame, all emitters together
  emit_total:       u32,
  // ring slot of the frame's first new particle
  emit_cursor:      u32,
}

// FrameCamera is a live camera as frame records it; textures and slots are this frame's.
FrameCamera :: struct {
  index:        u32,
  attachments:  [AttachmentType]TextureHandle,
  // the previous frame's depth, which the depth pyramid is built from
  prev_depth:   TextureHandle,
  // the depth pyramid built this frame
  pyramid:      TextureHandle,
  // this frame's pyramid and draw-list slot; this frame's cull writes the lists of next_slot
  slot:         u32,
  next_slot:    u32,
  near, far:    f32,
  // its draw lists and pyramid hold data: until then the camera draws nothing
  ready:       bool,
}

// FrameDesc is everything frame records.
FrameDesc :: struct {
  // the window's size in pixels, as the platform reports it
  framebuffer_size:     [2]u32,
  // render's tables, the one copy; bit r of dirty[t] is region r of tables[t] (TABLE_REGIONS),
  // written since the last submitted frame
  tables:               [Table][]u8,
  dirty:                [Table]u64,
  live_cameras:         []FrameCamera,
  // index into live_cameras of the camera presented to the swapchain, -1 for none
  main_live:            int,
  // camera views covered by the cull dispatch, from CAMERA_VIEW_BASE + 1
  camera_view_count:    u32,
  node_count:           u32,
  // batch ids in use are below this (Table.BATCHES)
  batch_count:          u32,
  // lights are sorted by type; point and spot draw these volume meshes
  light_count:          [LightType]u32,
  light_volumes:        [LightType]MeshData,
  shadow_view_count:    u32,
  // draw-list slot the shadow views cull into and draw from
  shadow_draw_list:     u32,
  environment_map:      TextureHandle,
  brdf_lut:             TextureHandle,
  irradiance_cube:      TextureHandle,
  prefilter_cube:       TextureHandle,
  skybox_intensity:     f32,
  skybox_blur:          f32,
  // over the main camera's image, the last one presenting
  post_passes:          []PostPass,
  particle_params:      ParticleSystemParams,
  // filled segments of each debug line ring
  debug_line_counts:    [2]u32,
  // render clock time; the shader skips segments past their expiry
  debug_line_time:      f32,
  ui_batches:           []UIBatch,
  ui_vertices:          []Vertex2D,
  ui_indices:           []u32,
}

// FrameStatus is how frame went: RESIZE asks for resize at the new framebuffer size.
FrameStatus :: enum {
  OK,
  RESIZE,
  ERROR,
}
