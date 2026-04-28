package graph

import "../../gpu"
import vk "vendor:vulkan"

graph_execute :: proc(g: ^Graph, cmd: vk.CommandBuffer) -> vk.Result {
  for ph, idx in g.order {
    p := &g.passes[ph]
    if p.culled do continue
    insert_barriers(g, p, cmd)
    auto_render := p.kind == .Graphics && !p.manual_rendering
    began := false
    if auto_render {
      began = begin_dynamic_rendering(g, p, cmd)
    }
    if p.execute != nil {
      ctx := ExecuteContext {
        cmd         = cmd,
        frame_index = g.frame_index,
        pass_index  = u32(idx),
      }
      p.execute(g, ctx, p.user_data)
    }
    if began {
      vk.CmdEndRendering(cmd)
    }
    update_resource_state(g, p)
  }
  return .SUCCESS
}

insert_barriers :: proc(g: ^Graph, p: ^PassDecl, cmd: vk.CommandBuffer) {
  for w in p.writes {
    barrier_for_access(g, p, w, cmd)
  }
  for rd in p.reads {
    barrier_for_access(g, p, rd, cmd)
  }
}

barrier_for_access :: proc(
  g: ^Graph,
  p: ^PassDecl,
  a: Access,
  cmd: vk.CommandBuffer,
) {
  r := &g.resources[a.resource]
  if !resource_is_image(r) {
    barrier_for_buffer_access(g, p, a, cmd)
    return
  }
  img, _ := resource_image(r)
  if img == 0 do return
  new_layout := access_layout(a.kind)
  new_stage := access_stage(a.kind, p.kind)
  new_access := access_mask(a.kind)
  is_write := is_write_access(a.kind)
  full := is_full_image_access(r, a)
  // Fast path: full-range access, no per-subresource divergence yet.
  if full && r.subresource_offset < 0 {
    if r.current_layout == new_layout &&
       r.last_stage == new_stage &&
       !is_write &&
       r.last_access == new_access {
      return
    }
    src_stage := r.last_stage
    if src_stage == {} do src_stage = {.TOP_OF_PIPE}
    d := r.desc.(ImageDesc)
    barrier := vk.ImageMemoryBarrier {
      sType = .IMAGE_MEMORY_BARRIER,
      oldLayout = r.current_layout,
      newLayout = new_layout,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = img,
      srcAccessMask = r.last_access,
      dstAccessMask = new_access,
      subresourceRange = {
        aspectMask = resource_image_aspect(r),
        baseMipLevel = 0,
        levelCount = d.mip_levels,
        baseArrayLayer = 0,
        layerCount = d.array_layers,
      },
    }
    vk.CmdPipelineBarrier(cmd, src_stage, new_stage, {}, 0, nil, 0, nil, 1, &barrier)
    r.current_layout = new_layout
    r.last_stage = new_stage
    r.last_access = new_access
    return
  }
  // Partial-range or already-divergent: walk per-subresource and emit a barrier
  // per entry whose state differs from the target.
  ensure_subresource_state(g, r)
  bm, mc, bl, lc := resolve_subresource_range(r, a)
  d := r.desc.(ImageDesc)
  aspect := resource_image_aspect(r)
  for mip in bm ..< bm + mc {
    for layer in bl ..< bl + lc {
      cur := get_subresource_state(g, r, mip, layer)
      if cur.layout == new_layout &&
         cur.stage == new_stage &&
         !is_write &&
         cur.access == new_access {
        continue
      }
      src_stage := cur.stage
      if src_stage == {} do src_stage = {.TOP_OF_PIPE}
      barrier := vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = cur.layout,
        newLayout = new_layout,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = img,
        srcAccessMask = cur.access,
        dstAccessMask = new_access,
        subresourceRange = {
          aspectMask = aspect,
          baseMipLevel = mip,
          levelCount = 1,
          baseArrayLayer = layer,
          layerCount = 1,
        },
      }
      vk.CmdPipelineBarrier(cmd, src_stage, new_stage, {}, 0, nil, 0, nil, 1, &barrier)
      set_subresource_state(g, r, mip, layer, SubresourceState{new_layout, new_stage, new_access})
    }
  }
  // Refresh flat fields when full-range single-subresource path resumes after
  // divergence — leave divergent entries authoritative in subresource_state.
  _ = d
}

update_resource_state :: proc(g: ^Graph, p: ^PassDecl) {
  // current_layout/last_stage/last_access already updated in barrier_for_access.
  // Finalize for write accesses that may not have emitted a barrier (e.g. when
  // the access kind matched prior state). Subresource_state, when allocated,
  // is already authoritative — only update flat fields for images that never
  // diverged.
  for w in p.writes {
    r := &g.resources[w.resource]
    new_state := SubresourceState {
      layout = access_layout(w.kind),
      stage  = access_stage(w.kind, p.kind),
      access = access_mask(w.kind),
    }
    if resource_is_image(r) {
      if r.subresource_offset < 0 {
        r.current_layout = new_state.layout
        r.last_stage = new_state.stage
        r.last_access = new_state.access
      } else {
        bm, mc, bl, lc := resolve_subresource_range(r, w)
        for mip in bm ..< bm + mc {
          for layer in bl ..< bl + lc {
            set_subresource_state(g, r, mip, layer, new_state)
          }
        }
      }
    } else {
      r.last_stage = new_state.stage
      r.last_access = new_state.access
    }
    r.write_count += 1
  }
}

barrier_for_buffer_access :: proc(
  g: ^Graph,
  p: ^PassDecl,
  a: Access,
  cmd: vk.CommandBuffer,
) {
  r := &g.resources[a.resource]
  buf := resource_buffer(r)
  if buf == 0 do return
  new_stage := access_stage(a.kind, p.kind)
  new_access := access_mask(a.kind)
  // RAR (read-after-read) without intervening write needs no barrier.
  prev_was_write := r.last_access & {.SHADER_WRITE, .TRANSFER_WRITE, .COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE} != {}
  if !is_write_access(a.kind) && !prev_was_write {
    return
  }
  src_stage := r.last_stage
  if src_stage == {} do src_stage = {.TOP_OF_PIPE}
  size: vk.DeviceSize = 0
  switch d in r.desc {
  case BufferDesc:
    size = d.size
  case ImageDesc:
  }
  if size == 0 {
    switch p in r.physical {
    case ImportedBuffer:
      size = p.size
    case vk.Buffer, gpu.Image, ImportedImage:
    }
  }
  if size == 0 do size = vk.DeviceSize(vk.WHOLE_SIZE)
  barrier := vk.BufferMemoryBarrier {
    sType               = .BUFFER_MEMORY_BARRIER,
    srcAccessMask       = r.last_access,
    dstAccessMask       = new_access,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer              = buf,
    offset              = 0,
    size                = size,
  }
  vk.CmdPipelineBarrier(
    cmd,
    src_stage,
    new_stage,
    {},
    0,
    nil,
    1,
    &barrier,
    0,
    nil,
  )
  r.last_stage = new_stage
  r.last_access = new_access
}

resolve_load_op :: proc(op: LoadOp, r: ^Resource) -> vk.AttachmentLoadOp {
  switch op {
  case .Auto:
    return r.write_count == 0 ? .CLEAR : .LOAD
  case .Clear:
    return .CLEAR
  case .Load:
    return .LOAD
  case .DontCare:
    return .DONT_CARE
  }
  return .CLEAR
}

@(private = "file")
resolve_store_op :: proc(op: StoreOp) -> vk.AttachmentStoreOp {
  switch op {
  case .Auto, .Store:
    return .STORE
  case .DontCare:
    return .DONT_CARE
  }
  return .STORE
}

MAX_COLOR_ATTACHMENTS :: 8

begin_dynamic_rendering :: proc(
  g: ^Graph,
  p: ^PassDecl,
  cmd: vk.CommandBuffer,
) -> bool {
  color_attachments: [MAX_COLOR_ATTACHMENTS]vk.RenderingAttachmentInfo
  color_count: u32 = 0
  has_depth := false
  depth_attachment: vk.RenderingAttachmentInfo
  extent: vk.Extent2D
  extent_set := false
  for w in p.writes {
    r := &g.resources[w.resource]
    if !resource_is_image(r) do continue
    _, view := resource_image(r)
    if view == 0 do continue
    d := r.desc.(ImageDesc)
    if !extent_set {
      extent = d.extent
      extent_set = true
    } else {
      assert(
        extent == d.extent,
        "render graph: pass writes attachments with mismatched extents",
      )
    }
    #partial switch w.kind {
    case .ColorAttachment:
      assert(
        color_count < MAX_COLOR_ATTACHMENTS,
        "render graph: pass exceeds MAX_COLOR_ATTACHMENTS color writes",
      )
      color_attachments[color_count] = vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = view,
        imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
        loadOp = resolve_load_op(w.load_op, r),
        storeOp = resolve_store_op(w.store_op),
        clearValue = {color = {float32 = {0, 0, 0, 0}}},
      }
      color_count += 1
    case .DepthAttachment:
      depth_attachment = vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = view,
        imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
        loadOp = resolve_load_op(w.load_op, r),
        storeOp = resolve_store_op(w.store_op),
        clearValue = {depthStencil = {depth = 1.0, stencil = 0}},
      }
      has_depth = true
    }
  }
  if color_count == 0 && !has_depth do return false
  info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {offset = {0, 0}, extent = extent},
    layerCount = 1,
    colorAttachmentCount = color_count,
    pColorAttachments = &color_attachments[0],
  }
  if has_depth {
    info.pDepthAttachment = &depth_attachment
  }
  vk.CmdBeginRendering(cmd, &info)
  return true
}
