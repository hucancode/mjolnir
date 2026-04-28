package graph

import "../../gpu"
import vk "vendor:vulkan"

ResourceHandle :: distinct u32
PassHandle :: distinct u32

INVALID_RESOURCE :: ResourceHandle(max(u32))
INVALID_PASS :: PassHandle(max(u32))

ImageDesc :: struct {
  extent:       vk.Extent2D,
  format:       vk.Format,
  mip_levels:   u32,
  array_layers: u32,
  samples:      vk.SampleCountFlag,
  usage_hint:   vk.ImageUsageFlags,
  type:         gpu.ImageType,
  name:         string,
}

BufferDesc :: struct {
  size:  vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  name:  string,
}

ResourceDesc :: union {
  ImageDesc,
  BufferDesc,
}

ImportedImage :: struct {
  image:          vk.Image,
  view:           vk.ImageView,
  format:         vk.Format,
  extent:         vk.Extent2D,
  initial_layout: vk.ImageLayout,
}

ImportedBuffer :: struct {
  buffer: vk.Buffer,
  size:   vk.DeviceSize,
}

ResourcePhysical :: union {
  gpu.Image,       // transient image owned by graph
  vk.Buffer,       // transient buffer (later phase)
  ImportedImage,
  ImportedBuffer,
}

SubresourceState :: struct {
  layout: vk.ImageLayout,
  stage:  vk.PipelineStageFlags,
  access: vk.AccessFlags,
}

Resource :: struct {
  desc:              ResourceDesc,
  imported:          bool,
  physical:          ResourcePhysical,
  // tracking
  producers:         [dynamic]PassHandle,
  consumers:         [dynamic]PassHandle,
  first_use:         i32,
  last_use:          i32,
  ref_count:         u32,
  // alias plan (transient images only)
  alias_slot:        i32, // -1 if no slot assigned
  // execution state — flat fields used when subresource_state is nil
  // (single subresource OR no partial access has been seen).
  current_layout:    vk.ImageLayout,
  last_stage:        vk.PipelineStageFlags,
  last_access:       vk.AccessFlags,
  // Lazy per-subresource state. -1 means "use flat fields above". Otherwise
  // indexes into Graph.subresource_buf at [offset, offset+count).
  subresource_offset: i32,
  subresource_count:  i32,
  // Number of writes encountered so far during execution; load_op=.Auto picks
  // CLEAR on the first write, LOAD afterward.
  write_count:       u32,
  // Bumped every time a writer declares this resource. Versions are advisory
  // metadata in the current API — they let callers rebind locals after a write
  // and make data flow explicit.
  version:           u32,
}

ImageKey :: struct {
  extent:       vk.Extent2D,
  format:       vk.Format,
  samples:      vk.SampleCountFlag,
  array_layers: u32,
  mip_levels:   u32,
  usage:        vk.ImageUsageFlags,
  type:         gpu.ImageType,
}

TransientSlot :: struct {
  image:           gpu.Image,
  // last graph-pass index this slot is occupied through (within current frame)
  available_after: i32,
}

TransientBucket :: struct {
  key:   ImageKey,
  slots: [dynamic]TransientSlot,
}

Transient_Pool :: struct {
  buckets: [dynamic]TransientBucket,
}

transient_pool_init :: proc(p: ^Transient_Pool) {
  p.buckets = make([dynamic]TransientBucket, 0, 4)
}

transient_pool_shutdown :: proc(p: ^Transient_Pool, gctx: ^gpu.GPUContext) {
  for &b in p.buckets {
    for &s in b.slots {
      gpu.image_destroy(gctx.device, &s.image)
    }
    delete(b.slots)
  }
  delete(p.buckets)
}

transient_pool_reset :: proc(p: ^Transient_Pool) {
  for &b in p.buckets {
    for &s in b.slots {
      s.available_after = -1
    }
  }
}

// Acquire a slot whose previous tenant finished by `first_use - 1`. Returns
// slot index within the bucket, or creates a new slot. Caller updates
// `available_after` on the returned slot to reserve it through `last_use`.
transient_pool_acquire :: proc(
  p: ^Transient_Pool,
  gctx: ^gpu.GPUContext,
  key: ImageKey,
  first_use: i32,
) -> (
  bucket_idx: int,
  slot_idx: int,
  ret: vk.Result,
) {
  bucket_idx = -1
  for &b, i in p.buckets {
    if b.key == key {
      bucket_idx = i
      break
    }
  }
  if bucket_idx < 0 {
    append(&p.buckets, TransientBucket{key = key, slots = make([dynamic]TransientSlot, 0, 2)})
    bucket_idx = len(p.buckets) - 1
  }
  bucket := &p.buckets[bucket_idx]
  for &s, i in bucket.slots {
    if s.available_after < first_use {
      slot_idx = i
      ret = .SUCCESS
      return
    }
  }
  // No reusable slot — allocate new image into the bucket.
  spec := gpu.ImageSpec {
    type         = key.type if key.type != gpu.ImageType(0) else .D2,
    extent       = key.extent,
    array_layers = key.array_layers,
    format       = key.format,
    mip_levels   = key.mip_levels,
    tiling       = .OPTIMAL,
    usage        = key.usage,
    memory_flags = {.DEVICE_LOCAL},
    create_view  = true,
  }
  img: gpu.Image
  img, ret = gpu.image_create(gctx, spec)
  if ret != .SUCCESS do return
  append(&bucket.slots, TransientSlot{image = img, available_after = -1})
  slot_idx = len(bucket.slots) - 1
  return
}

// Idempotent: re-importing the same name returns the existing handle without
// creating a new Resource. Caller-provided `img` is ignored on re-import — the
// first import wins. Use this to let multiple pass-builders import the same
// engine-fed resource without collision.
graph_import_image :: proc(
  g: ^Graph,
  name: string,
  img: ImportedImage,
) -> ResourceHandle {
  if name != "" {
    if existing, ok := g.imports[name]; ok {
      return existing
    }
  }
  r := Resource {
    desc               = ImageDesc {
      extent = img.extent,
      format = img.format,
      mip_levels = 1,
      array_layers = 1,
      type = .D2,
      name = name,
    },
    imported           = true,
    physical           = img,
    alias_slot         = -1,
    current_layout     = img.initial_layout,
    subresource_offset = -1,
  }
  append(&g.resources, r)
  h := ResourceHandle(len(g.resources) - 1)
  if name != "" {
    g.imports[name] = h
  }
  return h
}

// Idempotent: see graph_import_image.
graph_import_buffer :: proc(
  g: ^Graph,
  name: string,
  buf: vk.Buffer,
  size: vk.DeviceSize,
) -> ResourceHandle {
  if name != "" {
    if existing, ok := g.imports[name]; ok {
      return existing
    }
  }
  r := Resource {
    desc               = BufferDesc{size = size, usage = {}, name = name},
    imported           = true,
    physical           = ImportedBuffer{buffer = buf, size = size},
    alias_slot         = -1,
    subresource_offset = -1,
  }
  append(&g.resources, r)
  h := ResourceHandle(len(g.resources) - 1)
  if name != "" {
    g.imports[name] = h
  }
  return h
}

graph_create_image :: proc(g: ^Graph, desc: ImageDesc) -> ResourceHandle {
  d := desc
  if d.mip_levels == 0 do d.mip_levels = 1
  if d.array_layers == 0 do d.array_layers = 1
  if d.samples == {} do d.samples = ._1
  r := Resource {
    desc               = d,
    imported           = false,
    alias_slot         = -1,
    current_layout     = .UNDEFINED,
    subresource_offset = -1,
  }
  append(&g.resources, r)
  return ResourceHandle(len(g.resources) - 1)
}

graph_create_buffer :: proc(g: ^Graph, desc: BufferDesc) -> ResourceHandle {
  r := Resource {
    desc               = desc,
    imported           = false,
    alias_slot         = -1,
    subresource_offset = -1,
  }
  append(&g.resources, r)
  return ResourceHandle(len(g.resources) - 1)
}

resource_is_image :: proc(r: ^Resource) -> bool {
  _, ok := r.desc.(ImageDesc)
  return ok
}

resource_image :: proc(r: ^Resource) -> (vk.Image, vk.ImageView) {
  switch p in r.physical {
  case gpu.Image:
    return p.image, p.view
  case ImportedImage:
    return p.image, p.view
  case vk.Buffer, ImportedBuffer:
    return 0, 0
  }
  return 0, 0
}

resource_buffer :: proc(r: ^Resource) -> vk.Buffer {
  switch p in r.physical {
  case vk.Buffer:
    return p
  case ImportedBuffer:
    return p.buffer
  case gpu.Image, ImportedImage:
    return 0
  }
  return 0
}

// Resolve an Access subresource range against the resource's image desc.
// 0 counts mean "remaining" (FULL_REMAINING semantics).
resolve_subresource_range :: proc(
  r: ^Resource,
  a: Access,
) -> (
  base_mip, mip_count, base_layer, layer_count: u32,
) {
  d, ok := r.desc.(ImageDesc)
  if !ok {
    return 0, 1, 0, 1
  }
  base_mip = a.base_mip
  mip_count = a.mip_count
  if mip_count == 0 || base_mip + mip_count > d.mip_levels {
    mip_count = d.mip_levels - base_mip
  }
  base_layer = a.base_layer
  layer_count = a.layer_count
  if layer_count == 0 || base_layer + layer_count > d.array_layers {
    layer_count = d.array_layers - base_layer
  }
  return
}

is_full_image_access :: proc(r: ^Resource, a: Access) -> bool {
  d, ok := r.desc.(ImageDesc)
  if !ok do return true
  bm, mc, bl, lc := resolve_subresource_range(r, a)
  return bm == 0 && bl == 0 && mc == d.mip_levels && lc == d.array_layers
}

ensure_subresource_state :: proc(g: ^Graph, r: ^Resource) {
  if r.subresource_offset >= 0 do return
  d, ok := r.desc.(ImageDesc)
  if !ok do return
  total := int(d.mip_levels) * int(d.array_layers)
  if total <= 1 do return
  off := i32(len(g.subresource_buf))
  init := SubresourceState{r.current_layout, r.last_stage, r.last_access}
  for _ in 0 ..< total {
    append(&g.subresource_buf, init)
  }
  r.subresource_offset = off
  r.subresource_count = i32(total)
}

@(private = "file")
sub_index :: #force_inline proc(d: ImageDesc, mip, layer: u32) -> int {
  return int(mip) * int(d.array_layers) + int(layer)
}

get_subresource_state :: proc(g: ^Graph, r: ^Resource, mip, layer: u32) -> SubresourceState {
  if r.subresource_offset < 0 {
    return SubresourceState{r.current_layout, r.last_stage, r.last_access}
  }
  d := r.desc.(ImageDesc)
  return g.subresource_buf[int(r.subresource_offset) + sub_index(d, mip, layer)]
}

set_subresource_state :: proc(g: ^Graph, r: ^Resource, mip, layer: u32, s: SubresourceState) {
  if r.subresource_offset < 0 {
    r.current_layout = s.layout
    r.last_stage = s.stage
    r.last_access = s.access
    return
  }
  d := r.desc.(ImageDesc)
  g.subresource_buf[int(r.subresource_offset) + sub_index(d, mip, layer)] = s
}

resource_image_aspect :: proc(r: ^Resource) -> vk.ImageAspectFlags {
  d, ok := r.desc.(ImageDesc)
  if !ok do return {}
  return gpu.infer_aspect_mask(d.format)
}

allocate_transient_image :: proc(
  gctx: ^gpu.GPUContext,
  d: ImageDesc,
  usage: vk.ImageUsageFlags,
) -> (
  img: gpu.Image,
  ret: vk.Result,
) {
  spec := gpu.ImageSpec {
    type         = d.type == gpu.ImageType(0) ? .D2 : d.type,
    extent       = d.extent,
    array_layers = d.array_layers,
    format       = d.format,
    mip_levels   = d.mip_levels,
    tiling       = .OPTIMAL,
    usage        = usage,
    memory_flags = {.DEVICE_LOCAL},
    create_view  = true,
  }
  return gpu.image_create(gctx, spec)
}
