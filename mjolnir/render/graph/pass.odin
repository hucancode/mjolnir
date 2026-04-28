package graph

import vk "vendor:vulkan"

// Pattern: typed pass with execute via blackboard-allocated user data
// =====================================================
// The C++ FrameGraph reference uses templated lambdas to capture per-pass data.
// In Odin we use the per-frame Blackboard plus an untyped user_data pointer
// cast back to the typed struct inside the execute procedure:
//
//   GeometryData :: struct {
//     pos, depth: ResourceHandle,
//     manager:    ^MyManager,
//   }
//
//   geometry_execute :: proc(g: ^Graph, ctx: ExecuteContext, ud: rawptr) {
//     d := cast(^GeometryData)ud
//     // ... use d.manager, d.pos, d.depth ...
//   }
//
//   data := blackboard_add(&g.blackboard, "geometry.exec", GeometryData)
//   data^ = GeometryData{ manager = self, ... }
//   pass := graph_add_pass(&g, "geometry", .Graphics, geometry_execute, data)
//   data.pos   = pass_write(&g, pass, pos_h, .ColorAttachment)
//   data.depth = pass_write(&g, pass, depth_h, .DepthAttachment)
//
// Blackboard storage lives until the next graph_begin_frame, so the execute
// callback can dereference it safely.

// Single-queue model: all passes record into one command buffer.
// Cross-queue ownership transfer is not yet implemented.
PassKind :: enum {
  Graphics,
  Compute,
  Transfer,
}

AccessKind :: enum {
  Sampled,
  ColorAttachment,
  DepthAttachment,
  DepthRead,
  StorageRead,
  StorageWrite,
  StorageReadWrite,
  IndirectArg,
  TransferSrc,
  TransferDst,
  Present,
}

// LoadOp/StoreOp control begin_dynamic_rendering attachment behavior. Auto
// resolves at execute time: first writer to a resource clears, subsequent
// writers load. DontCare maps to vk.AttachmentLoadOp.DONT_CARE.
LoadOp :: enum u8 {
  Auto,
  Clear,
  Load,
  DontCare,
}

StoreOp :: enum u8 {
  Auto,
  Store,
  DontCare,
}

// Access describes one resource access within a pass. Subresource ranges:
// mip_count == 0 means [base_mip, mip_levels); same for layer_count. Default
// 0/0/0/0 covers the full image, matching the common case.
Access :: struct {
  resource:    ResourceHandle,
  kind:        AccessKind,
  base_mip:    u32,
  mip_count:   u32,
  base_layer:  u32,
  layer_count: u32,
  load_op:     LoadOp,
  store_op:    StoreOp,
}

ExecuteProc :: #type proc(g: ^Graph, ctx: ExecuteContext, user_data: rawptr)

PassDecl :: struct {
  name:             string,
  kind:             PassKind,
  reads:            [dynamic]Access,
  writes:           [dynamic]Access,
  side_effect:      bool,
  manual_rendering: bool, // skip graph-managed CmdBeginRendering for graphics passes
  execute:          ExecuteProc,
  user_data:        rawptr,
  // compile-time scratch
  ref_count:        u32,
  culled:           bool,
  order_index:      u32,
}

ExecuteContext :: struct {
  cmd:         vk.CommandBuffer,
  frame_index: u32,
  pass_index:  u32,
}

is_write_access :: proc(k: AccessKind) -> bool {
  #partial switch k {
  case .ColorAttachment,
       .DepthAttachment,
       .StorageWrite,
       .StorageReadWrite,
       .TransferDst:
    return true
  }
  return false
}

is_read_access :: proc(k: AccessKind) -> bool {
  #partial switch k {
  case .Sampled,
       .DepthRead,
       .StorageRead,
       .StorageReadWrite,
       .IndirectArg,
       .TransferSrc,
       .Present:
    return true
  }
  return false
}

access_layout :: proc(k: AccessKind) -> vk.ImageLayout {
  #partial switch k {
  case .Sampled:
    return .SHADER_READ_ONLY_OPTIMAL
  case .ColorAttachment:
    return .COLOR_ATTACHMENT_OPTIMAL
  case .DepthAttachment:
    return .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
  case .DepthRead:
    return .DEPTH_STENCIL_READ_ONLY_OPTIMAL
  case .StorageRead, .StorageWrite, .StorageReadWrite:
    return .GENERAL
  case .TransferSrc:
    return .TRANSFER_SRC_OPTIMAL
  case .TransferDst:
    return .TRANSFER_DST_OPTIMAL
  case .Present:
    return .PRESENT_SRC_KHR
  }
  return .UNDEFINED
}

access_stage :: proc(k: AccessKind, pass_kind: PassKind) -> vk.PipelineStageFlags {
  #partial switch k {
  case .Sampled:
    return pass_kind == .Compute ? {.COMPUTE_SHADER} : {.FRAGMENT_SHADER}
  case .ColorAttachment:
    return {.COLOR_ATTACHMENT_OUTPUT}
  case .DepthAttachment, .DepthRead:
    return {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
  case .StorageRead, .StorageWrite, .StorageReadWrite:
    return {.COMPUTE_SHADER}
  case .IndirectArg:
    return {.DRAW_INDIRECT}
  case .TransferSrc, .TransferDst:
    return {.TRANSFER}
  case .Present:
    return {.BOTTOM_OF_PIPE}
  }
  return {.TOP_OF_PIPE}
}

access_mask :: proc(k: AccessKind) -> vk.AccessFlags {
  #partial switch k {
  case .Sampled:
    return {.SHADER_READ}
  case .ColorAttachment:
    return {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
  case .DepthAttachment:
    return {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
  case .DepthRead:
    return {.DEPTH_STENCIL_ATTACHMENT_READ}
  case .StorageRead:
    return {.SHADER_READ}
  case .StorageWrite:
    return {.SHADER_WRITE}
  case .StorageReadWrite:
    return {.SHADER_READ, .SHADER_WRITE}
  case .IndirectArg:
    return {.INDIRECT_COMMAND_READ}
  case .TransferSrc:
    return {.TRANSFER_READ}
  case .TransferDst:
    return {.TRANSFER_WRITE}
  case .Present:
    return {}
  }
  return {}
}

access_image_usage :: proc(k: AccessKind) -> vk.ImageUsageFlags {
  #partial switch k {
  case .Sampled:
    return {.SAMPLED}
  case .ColorAttachment:
    return {.COLOR_ATTACHMENT}
  case .DepthAttachment, .DepthRead:
    return {.DEPTH_STENCIL_ATTACHMENT}
  case .StorageRead, .StorageWrite, .StorageReadWrite:
    return {.STORAGE}
  case .TransferSrc:
    return {.TRANSFER_SRC}
  case .TransferDst:
    return {.TRANSFER_DST}
  }
  return {}
}

access_buffer_usage :: proc(k: AccessKind) -> vk.BufferUsageFlags {
  #partial switch k {
  case .StorageRead, .StorageWrite, .StorageReadWrite:
    return {.STORAGE_BUFFER}
  case .IndirectArg:
    return {.INDIRECT_BUFFER}
  case .TransferSrc:
    return {.TRANSFER_SRC}
  case .TransferDst:
    return {.TRANSFER_DST}
  }
  return {}
}
