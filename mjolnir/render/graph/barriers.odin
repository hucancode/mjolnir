package render_graph

import "core:fmt"
import vk "vendor:vulkan"

// ============================================================================
// Barrier Computation
// ============================================================================

compute_barriers :: proc(graph: ^Graph) {
  resource_state := make(map[ResourceInstanceId]ResourceState)
  defer delete(resource_state)

  for pass_id in graph.sorted_passes {
    pass := get_pass(graph, pass_id)

    for read in pass.reads {
      is_also_written := false
      for write in pass.writes {
        if write.resource_name == read.resource_name {
          is_also_written = true
          break
        }
      }
      if is_also_written {continue}

      if read.frame_offset != .CURRENT {
        emit_memory_barrier(
          graph,
          pass_id,
          read.resource_name,
          read.frame_offset,
          .READ,
          pass.queue,
          &resource_state,
        )
      } else {
        emit_full_barrier(
          graph,
          pass_id,
          read.resource_name,
          read.frame_offset,
          .READ,
          pass.queue,
          &resource_state,
        )
      }
    }

    for write in pass.writes {
      if write.frame_offset != .CURRENT {
        emit_memory_barrier(
          graph,
          pass_id,
          write.resource_name,
          write.frame_offset,
          .WRITE,
          pass.queue,
          &resource_state,
        )
      } else {
        emit_full_barrier(
          graph,
          pass_id,
          write.resource_name,
          write.frame_offset,
          .WRITE,
          pass.queue,
          &resource_state,
        )
      }
    }

    update_resource_state(pass, &resource_state, graph)
  }
}

// ============================================================================
// Resource State Tracking
// ============================================================================

ResourceState :: struct {
  last_stage:  vk.PipelineStageFlags,
  last_access: vk.AccessFlags,
  last_layout: vk.ImageLayout,
  last_queue:  QueueType,
}

_phys_id :: proc(graph: ^Graph, res_id: ResourceInstanceId) -> ResourceInstanceId {
  res := get_resource(graph, res_id)
  if res.is_alias {return res.alias_target}
  return res_id
}

update_resource_state :: proc(
  pass: ^PassInstance,
  state: ^map[ResourceInstanceId]ResourceState,
  graph: ^Graph,
) {
  for write in pass.writes {
    if write.frame_offset != .CURRENT {continue}

    res: ^ResourceInstance = nil
    phys: ResourceInstanceId
    if res_id, found := find_resource_by_name(graph, write.resource_name); found {
      res = get_resource(graph, res_id)
      phys = _phys_id(graph, res_id)
    } else {
      continue
    }

    new_state := infer_resource_state_before_access(write.access_mode, pass.queue, res)
    (state^)[phys] = new_state
  }

  for read in pass.reads {
    if read.frame_offset != .CURRENT {continue}

    is_also_written := false
    for write in pass.writes {
      if write.resource_name == read.resource_name {
        is_also_written = true
        break
      }
    }
    if is_also_written {continue}

    if res_id, found := find_resource_by_name(graph, read.resource_name); found {
      res := get_resource(graph, res_id)
      phys := _phys_id(graph, res_id)
      new_state := infer_resource_state_before_access(.READ, pass.queue, res)
      (state^)[phys] = new_state
    }
  }
}

// ============================================================================
// Barrier Emission
// ============================================================================

emit_full_barrier :: proc(
  graph: ^Graph,
  pass_id: PassInstanceId,
  resource_name: string,
  frame_offset: FrameOffset,
  access: AccessMode,
  queue: QueueType,
  state: ^map[ResourceInstanceId]ResourceState,
) {
  res_id, found := find_resource_by_name(graph, resource_name)
  if !found {return}

  res := get_resource(graph, res_id)
  phys := _phys_id(graph, res_id)
  phys_res := get_resource(graph, phys)

  current_state, has_state := (state^)[phys]
  if !has_state {
    current_state = get_initial_resource_state(phys_res)
  }

  desired_state := infer_resource_state_before_access(access, queue, res)
  barrier := create_barrier(phys, phys_res, frame_offset, current_state, desired_state)
  add_barrier(graph, pass_id, barrier)
}

emit_memory_barrier :: proc(
  graph: ^Graph,
  pass_id: PassInstanceId,
  resource_name: string,
  frame_offset: FrameOffset,
  access: AccessMode,
  queue: QueueType,
  state: ^map[ResourceInstanceId]ResourceState,
) {
  res_id, found := find_resource_by_name(graph, resource_name)
  if !found {return}

  res := get_resource(graph, res_id)
  phys := _phys_id(graph, res_id)
  phys_res := get_resource(graph, phys)

  current_state, has_state := (state^)[phys]
  if !has_state {
    current_state = get_initial_resource_state(phys_res)
  }

  desired_state := infer_resource_state_before_access(access, queue, res)
  barrier := create_memory_barrier(phys, phys_res, frame_offset, current_state, desired_state)
  add_barrier(graph, pass_id, barrier)
}

// ============================================================================
// Barrier Creation
// ============================================================================

create_barrier :: proc(
  res_id: ResourceInstanceId,
  res: ^ResourceInstance,
  frame_offset: FrameOffset,
  from: ResourceState,
  to: ResourceState,
) -> Barrier {
  barrier := Barrier {
    resource_id  = res_id,
    frame_offset = frame_offset,
    src_access   = from.last_access,
    dst_access   = to.last_access,
    src_stage    = from.last_stage,
    dst_stage    = to.last_stage,
  }

  switch d in res.data {
  case ResourceTexture:
    barrier.old_layout = from.last_layout
    barrier.new_layout = to.last_layout
    barrier.aspect = d.aspect
  case ResourceTextureCube:
    barrier.old_layout = from.last_layout
    barrier.new_layout = to.last_layout
    barrier.aspect = d.aspect
  case ResourceBuffer:
  }

  return barrier
}

create_memory_barrier :: proc(
  res_id: ResourceInstanceId,
  res: ^ResourceInstance,
  frame_offset: FrameOffset,
  from: ResourceState,
  to: ResourceState,
) -> Barrier {
  barrier := create_barrier(res_id, res, frame_offset, from, to)
  barrier.src_stage = {.ALL_COMMANDS}
  barrier.dst_stage = {.ALL_COMMANDS}
  return barrier
}

// ============================================================================
// State Inference
// ============================================================================

get_initial_resource_state :: proc(res: ^ResourceInstance) -> ResourceState {
  return ResourceState {
    last_stage  = {.TOP_OF_PIPE},
    last_access = {},
    last_layout = .UNDEFINED,
    last_queue  = .GRAPHICS,
  }
}

infer_resource_state_before_access :: proc(
  access: AccessMode,
  queue: QueueType,
  res: ^ResourceInstance = nil,
) -> ResourceState {
  state := ResourceState{}

  is_depth := false
  if res != nil {
    switch d in res.data {
    case ResourceTexture:
      is_depth = .DEPTH in d.aspect || .STENCIL in d.aspect
    case ResourceTextureCube:
      is_depth = .DEPTH in d.aspect || .STENCIL in d.aspect
    case ResourceBuffer:
    }
  }

  switch queue {
  case .GRAPHICS:
    switch access {
    case .READ:
      if is_depth {
        state.last_stage = {.EARLY_FRAGMENT_TESTS}
        state.last_access = {.DEPTH_STENCIL_ATTACHMENT_READ}
        state.last_layout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL
      } else {
        state.last_stage = {.FRAGMENT_SHADER}
        state.last_access = {.SHADER_READ}
        state.last_layout = .SHADER_READ_ONLY_OPTIMAL
      }
    case .WRITE:
      if is_depth {
        state.last_stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
        state.last_access = {.DEPTH_STENCIL_ATTACHMENT_WRITE}
        state.last_layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      } else {
        state.last_stage = {.COLOR_ATTACHMENT_OUTPUT}
        state.last_access = {.COLOR_ATTACHMENT_WRITE}
        state.last_layout = .COLOR_ATTACHMENT_OPTIMAL
      }
    case .READ_WRITE:
      if is_depth {
        state.last_stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
        state.last_access = {
          .DEPTH_STENCIL_ATTACHMENT_READ,
          .DEPTH_STENCIL_ATTACHMENT_WRITE,
        }
        state.last_layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
      } else {
        state.last_stage = {.COLOR_ATTACHMENT_OUTPUT}
        state.last_access = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
        state.last_layout = .COLOR_ATTACHMENT_OPTIMAL
      }
    }

  case .COMPUTE:
    state.last_stage = {.COMPUTE_SHADER}
    switch access {
    case .READ:
      state.last_access = {.SHADER_READ}
      state.last_layout = .SHADER_READ_ONLY_OPTIMAL
    case .WRITE:
      state.last_access = {.SHADER_WRITE}
      state.last_layout = .GENERAL
    case .READ_WRITE:
      state.last_access = {.SHADER_READ, .SHADER_WRITE}
      state.last_layout = .GENERAL
    }
  }

  state.last_queue = queue

  return state
}
