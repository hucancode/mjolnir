package gpu

import "core:log"
import "core:mem"
import "core:slice"
import "core:sync"
import vk "vendor:vulkan"
import "../interval_tree"

DataBuffer :: struct($T: typeid) {
  buffer:       vk.Buffer,
  memory:       vk.DeviceMemory,
  mapped:       [^]T,
  element_size: int,
  bytes_count:  int,
}

malloc_data_buffer :: proc(
  gpu_context: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
) -> (
  data_buf: DataBuffer(T),
  ret: vk.Result,
) {
  if .UNIFORM_BUFFER in usage && count > 1 {
    data_buf.element_size = align_up(
      size_of(T),
      int(
        gpu_context.device_properties.limits.minUniformBufferOffsetAlignment,
      ),
    )
  } else if .STORAGE_BUFFER in usage && count > 1 {
    data_buf.element_size = align_up(
      size_of(T),
      int(
        gpu_context.device_properties.limits.minStorageBufferOffsetAlignment,
      ),
    )
  } else {
    data_buf.element_size = size_of(T)
  }
  data_buf.bytes_count = data_buf.element_size * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(data_buf.bytes_count),
    usage       = usage,
    sharingMode = .EXCLUSIVE,
  }
  vk.CreateBuffer(
    gpu_context.device,
    &create_info,
    nil,
    &data_buf.buffer,
  ) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(
    gpu_context.device,
    data_buf.buffer,
    &mem_reqs,
  )
  data_buf.memory = allocate_vulkan_memory(
    gpu_context,
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindBufferMemory(
    gpu_context.device,
    data_buf.buffer,
    data_buf.memory,
    0,
  ) or_return
  log.infof("buffer created 0x%x", data_buf.buffer)
  return data_buf, .SUCCESS
}

malloc_local_buffer :: proc(
  gpu_context: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  DataBuffer(T),
  vk.Result,
) {
  return malloc_data_buffer(gpu_context, T, count, usage, {.DEVICE_LOCAL})
}

malloc_host_visible_buffer :: proc(
  gpu_context: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  DataBuffer(T),
  vk.Result,
) {
  return malloc_data_buffer(
    gpu_context,
    T,
    count,
    usage,
    {.HOST_VISIBLE, .HOST_COHERENT},
  )
}

@(private = "file")
align_up :: proc(value: int, alignment: int) -> int {
  return (value + alignment - 1) & ~(alignment - 1)
}

write :: proc {
  data_buffer_write_single,
  data_buffer_write_multi,
  staged_buffer_write_single,
  staged_buffer_write_multi,
  static_buffer_write_single,
  static_buffer_write_multi,
}

data_buffer_write_single :: proc(
  self: ^DataBuffer($T),
  data: ^T,
  index: int = 0,
) -> vk.Result {
  if self.mapped == nil {
    return .ERROR_UNKNOWN
  }
  offset := index * self.element_size
  if offset + self.element_size > self.bytes_count {
    return .ERROR_UNKNOWN
  }
  destination := mem.ptr_offset(cast([^]u8)self.mapped, offset)
  mem.copy(destination, data, size_of(T))
  return .SUCCESS
}

data_buffer_write_multi :: proc(
  self: ^DataBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  if self.mapped == nil {
    return .ERROR_UNKNOWN
  }
  offset := index * self.element_size
  if offset + (self.element_size) * len(data) > self.bytes_count {
    return .ERROR_UNKNOWN
  }
  destination := mem.ptr_offset(cast([^]u8)self.mapped, offset)
  mem.copy(destination, raw_data(data), slice.size(data))
  return .SUCCESS
}

data_buffer_get :: proc(self: ^DataBuffer($T), index: u32 = 0) -> ^T {
  return &self.mapped[index]
}

data_buffer_get_all :: proc(self: ^DataBuffer($T)) -> []T {
  element_count := self.bytes_count / self.element_size
  return slice.from_ptr(self.mapped, element_count)
}

data_buffer_offset_of :: proc(self: ^DataBuffer($T), index: u32) -> u32 {
  return index * u32(self.element_size)
}

data_buffer_destroy :: proc(device: vk.Device, buffer: ^DataBuffer($T)) {
  if buffer.mapped != nil {
    vk.UnmapMemory(device, buffer.memory)
    buffer.mapped = nil
  }
  vk.DestroyBuffer(device, buffer.buffer, nil)
  buffer.buffer = 0
  vk.FreeMemory(device, buffer.memory, nil)
  buffer.memory = 0
  buffer.bytes_count = 0
  buffer.element_size = 0
}

create_host_visible_buffer :: proc(
  gpu_context: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer(T),
  ret: vk.Result,
) {
  buffer = malloc_host_visible_buffer(gpu_context, T, count, usage) or_return
  vk.MapMemory(
    gpu_context.device,
    buffer.memory,
    0,
    vk.DeviceSize(buffer.bytes_count),
    {},
    auto_cast &buffer.mapped,
  ) or_return
  log.infof("Init host visible buffer, buffer mapped at %v", &buffer.mapped)
  if data != nil {
    mem.copy(buffer.mapped, data, buffer.bytes_count)
  }
  ret = .SUCCESS
  return
}

create_local_buffer :: proc(
  gpu_context: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer(T),
  ret: vk.Result,
) {
  buffer = malloc_local_buffer(
    gpu_context,
    T,
    count,
    usage | {.TRANSFER_DST},
  ) or_return
  if data == nil {
    ret = .SUCCESS
    return
  }
  log.info("creating staging buffer with data ", data)
  staging := create_host_visible_buffer(
    gpu_context,
    T,
    count,
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer data_buffer_destroy(gpu_context.device, &staging)
  copy_buffer(gpu_context, buffer, staging) or_return
  ret = .SUCCESS
  return
}

@(private = "file")
copy_buffer :: proc(
  gpu_context: ^GPUContext,
  dst, src: DataBuffer($T),
) -> vk.Result {
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  region := vk.BufferCopy {
    size = vk.DeviceSize(src.bytes_count),
  }
  vk.CmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, &region)
  log.infof(
    "Copying buffer 0x%x mapped %x to 0x%x",
    src.buffer,
    src.mapped,
    dst.buffer,
  )
  return end_single_time_command(gpu_context, &cmd_buffer)
}


StaticBuffer :: struct($T: typeid) {
  buffer:       vk.Buffer,
  memory:       vk.DeviceMemory,
  element_size: int,
  bytes_count:  int,
}

malloc_static_buffer :: proc(
  gpu_context: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  buffer: StaticBuffer(T),
  ret: vk.Result,
) {
  if .UNIFORM_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(
        gpu_context.device_properties.limits.minUniformBufferOffsetAlignment,
      ),
    )
  } else if .STORAGE_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(
        gpu_context.device_properties.limits.minStorageBufferOffsetAlignment,
      ),
    )
  } else {
    buffer.element_size = size_of(T)
  }
  buffer.bytes_count = buffer.element_size * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(buffer.bytes_count),
    usage       = usage | {.TRANSFER_DST},
    sharingMode = .EXCLUSIVE,
  }
  vk.CreateBuffer(
    gpu_context.device,
    &create_info,
    nil,
    &buffer.buffer,
  ) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(
    gpu_context.device,
    buffer.buffer,
    &mem_reqs,
  )
  buffer.memory = allocate_vulkan_memory(
    gpu_context,
    mem_reqs,
    {.DEVICE_LOCAL},
  ) or_return
  vk.BindBufferMemory(
    gpu_context.device,
    buffer.buffer,
    buffer.memory,
    0,
  ) or_return
  log.infof("static buffer created 0x%x", buffer.buffer)
  return buffer, .SUCCESS
}

static_buffer_write :: proc {
  static_buffer_write_single,
  static_buffer_write_multi,
}

static_buffer_write_single :: proc(
  gpu_context: ^GPUContext,
  buffer: ^StaticBuffer($T),
  data: ^T,
  index: int = 0,
) -> vk.Result {
  staging := create_host_visible_buffer(
    gpu_context,
    T,
    1,
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer data_buffer_destroy(gpu_context.device, &staging)
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  offset := vk.DeviceSize(index * buffer.element_size)
  region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = offset,
    size = vk.DeviceSize(buffer.element_size),
  }
  vk.CmdCopyBuffer(cmd_buffer, staging.buffer, buffer.buffer, 1, &region)
  return end_single_time_command(gpu_context, &cmd_buffer)
}

static_buffer_write_multi :: proc(
  gpu_context: ^GPUContext,
  buffer: ^StaticBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  staging := create_host_visible_buffer(
    gpu_context,
    T,
    len(data),
    {.TRANSFER_SRC},
    raw_data(data),
  ) or_return
  defer data_buffer_destroy(gpu_context.device, &staging)
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  offset := vk.DeviceSize(index * buffer.element_size)
  region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = offset,
    size = vk.DeviceSize(buffer.element_size * len(data)),
  }
  vk.CmdCopyBuffer(cmd_buffer, staging.buffer, buffer.buffer, 1, &region)
  return end_single_time_command(gpu_context, &cmd_buffer)
}

static_buffer_offset_of :: proc(buffer: ^StaticBuffer($T), index: u32) -> u32 {
  return index * u32(buffer.element_size)
}

static_buffer_read :: proc(
  gpu_context: ^GPUContext,
  buffer: ^StaticBuffer($T),
  output: []T,
  index: int = 0,
) -> vk.Result {
  if len(output) == 0 do return .SUCCESS
  staging := create_host_visible_buffer(
    gpu_context,
    T,
    len(output),
    {.TRANSFER_DST},
  ) or_return
  defer data_buffer_destroy(gpu_context.device, &staging)
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  offset := vk.DeviceSize(index * buffer.element_size)
  region := vk.BufferCopy {
    srcOffset = offset,
    dstOffset = 0,
    size = vk.DeviceSize(buffer.element_size * len(output)),
  }
  vk.CmdCopyBuffer(cmd_buffer, buffer.buffer, staging.buffer, 1, &region)
  end_single_time_command(gpu_context, &cmd_buffer) or_return
  for i in 0..<len(output) {
    output[i] = staging.mapped[i]
  }
  return .SUCCESS
}

static_buffer_destroy :: proc(device: vk.Device, buffer: ^StaticBuffer($T)) {
  vk.DestroyBuffer(device, buffer.buffer, nil)
  buffer.buffer = 0
  vk.FreeMemory(device, buffer.memory, nil)
  buffer.memory = 0
  buffer.bytes_count = 0
  buffer.element_size = 0
}

StagedBuffer :: struct($T: typeid) {
  using staging: DataBuffer(T),
  dirty_indices: interval_tree.IntervalTree,
  dirty_mutex:   sync.Mutex,
  device_buffer: vk.Buffer,
  device_memory: vk.DeviceMemory,
}

malloc_staged_buffer :: proc(
  gpu_context: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  buffer: StagedBuffer(T),
  ret: vk.Result,
) {
  if .UNIFORM_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(
        gpu_context.device_properties.limits.minUniformBufferOffsetAlignment,
      ),
    )
  } else if .STORAGE_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(
        gpu_context.device_properties.limits.minStorageBufferOffsetAlignment,
      ),
    )
  } else {
    buffer.element_size = size_of(T)
  }
  buffer.bytes_count = buffer.element_size * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(buffer.bytes_count),
    usage       = usage,
    sharingMode = .EXCLUSIVE,
  }
  vk.CreateBuffer(
    gpu_context.device,
    &create_info,
    nil,
    &buffer.staging.buffer,
  ) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(
    gpu_context.device,
    buffer.staging.buffer,
    &mem_reqs,
  )
  buffer.staging.memory = allocate_vulkan_memory(
    gpu_context,
    mem_reqs,
    {.HOST_VISIBLE, .HOST_COHERENT},
  ) or_return
  vk.BindBufferMemory(
    gpu_context.device,
    buffer.staging.buffer,
    buffer.staging.memory,
    0,
  ) or_return
  // Map staging buffer memory for CPU access
  vk.MapMemory(
    gpu_context.device,
    buffer.staging.memory,
    0,
    vk.DeviceSize(buffer.bytes_count),
    {},
    auto_cast &buffer.staging.mapped,
  ) or_return
  // Create device buffer (GPU-local)
  create_info.usage = usage | {.TRANSFER_DST}
  vk.CreateBuffer(
    gpu_context.device,
    &create_info,
    nil,
    &buffer.device_buffer,
  ) or_return
  vk.GetBufferMemoryRequirements(
    gpu_context.device,
    buffer.device_buffer,
    &mem_reqs,
  )
  buffer.device_memory = allocate_vulkan_memory(
    gpu_context,
    mem_reqs,
    {.DEVICE_LOCAL},
  ) or_return
  vk.BindBufferMemory(
    gpu_context.device,
    buffer.device_buffer,
    buffer.device_memory,
    0,
  ) or_return
  interval_tree.init(&buffer.dirty_indices)
  // Mutex is zero-initialized by default in Odin
  // Mark all indices as dirty initially
  for i in 0..<count {
    interval_tree.insert(&buffer.dirty_indices, i, 1)
  }
  log.infof("staged buffer created 0x%x", buffer.staging.buffer)
  return buffer, .SUCCESS
}

flush :: proc(
  command_buffer: vk.CommandBuffer,
  buffer: ^StagedBuffer($T),
) -> vk.Result {
  // @(static) run_count := 0
  // if run_count >= 100 {
      // return .SUCCESS
  // }
  // defer run_count += 1

  // Lock to prevent race conditions with write operations
  sync.mutex_lock(&buffer.dirty_mutex)
  defer sync.mutex_unlock(&buffer.dirty_mutex)

  defer interval_tree.clear(&buffer.dirty_indices)
  copy_regions := make([dynamic]vk.BufferCopy, 0)
  defer delete(copy_regions)
  element_size := vk.DeviceSize(buffer.element_size)
  // Get all dirty intervals directly from interval tree
  intervals := interval_tree.get_ranges(&buffer.dirty_indices)
  total := 0
  max_elements := buffer.staging.bytes_count / buffer.staging.element_size

  for interval in intervals {
    // Validate interval bounds to prevent corruption
    if interval.start < 0 || interval.end < interval.start || interval.start >= max_elements {
      log.errorf("Invalid interval detected: start=%d, end=%d, max_elements=%d",
                 interval.start, interval.end, max_elements)
      continue
    }

    range_length := interval.end - interval.start + 1

    // Clamp range to buffer bounds
    if interval.end >= max_elements {
      range_length = max_elements - interval.start
    }

    if range_length <= 0 {
      continue
    }

    total += range_length
    append(
      &copy_regions,
      vk.BufferCopy {
        srcOffset = vk.DeviceSize(interval.start) * element_size,
        dstOffset = vk.DeviceSize(interval.start) * element_size,
        size = vk.DeviceSize(range_length) * element_size,
      },
    )
  }
  if len(copy_regions) == 0 {
    return .SUCCESS
  }
  // Barrier to ensure staging buffer writes are complete before copy
  staging_barrier := vk.BufferMemoryBarrier {
    sType = .BUFFER_MEMORY_BARRIER,
    srcAccessMask = {.HOST_WRITE},
    dstAccessMask = {.TRANSFER_READ},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer = buffer.staging.buffer,
    offset = 0,
    size = vk.DeviceSize(buffer.staging.bytes_count),
  }
  // Barrier to ensure device buffer is ready for writes
  device_pre_barrier := vk.BufferMemoryBarrier {
    sType = .BUFFER_MEMORY_BARRIER,
    srcAccessMask = {.SHADER_READ, .UNIFORM_READ},
    dstAccessMask = {.TRANSFER_WRITE},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer = buffer.device_buffer,
    offset = 0,
    size = vk.DeviceSize(buffer.staging.bytes_count),
  }
  barriers := [?]vk.BufferMemoryBarrier{staging_barrier, device_pre_barrier}
  vk.CmdPipelineBarrier(
    command_buffer,
    {.HOST, .VERTEX_SHADER, .FRAGMENT_SHADER, .COMPUTE_SHADER},
    {.TRANSFER},
    {},
    0, nil,
    2, raw_data(barriers[:]),
    0, nil,
  )
  vk.CmdCopyBuffer(
    command_buffer,
    buffer.staging.buffer,
    buffer.device_buffer,
    u32(len(copy_regions)),
    raw_data(copy_regions),
  )
  device_post_barrier := vk.BufferMemoryBarrier {
    sType = .BUFFER_MEMORY_BARRIER,
    srcAccessMask = {.TRANSFER_WRITE},
    dstAccessMask = {.SHADER_READ, .UNIFORM_READ},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer = buffer.device_buffer,
    offset = 0,
    size = vk.DeviceSize(buffer.staging.bytes_count),
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.VERTEX_SHADER, .FRAGMENT_SHADER, .COMPUTE_SHADER},
    {},
    0, nil,
    1, &device_post_barrier,
    0, nil,
  )
  log.infof("Copied %d items using %d commands from staging buffer to device buffer", total, len(copy_regions))
  return .SUCCESS
}

// Write a single element to the staging buffer and mark as dirty
staged_buffer_write_single :: proc(
  buffer: ^StagedBuffer($T),
  data: ^T,
  index: int = 0,
) -> vk.Result {
  if buffer.staging.mapped == nil {
    return .ERROR_UNKNOWN
  }
  data_buffer_write_single(&buffer.staging, data, index) or_return

  // Protect dirty_indices from concurrent access
  sync.mutex_lock(&buffer.dirty_mutex)
  defer sync.mutex_unlock(&buffer.dirty_mutex)
  interval_tree.insert(&buffer.dirty_indices, index, 1)

  return .SUCCESS
}

// Write multiple elements to the staging buffer and mark range as dirty
staged_buffer_write_multi :: proc(
  buffer: ^StagedBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  if buffer.staging.mapped == nil {
    return .ERROR_UNKNOWN
  }
  data_buffer_write_multi(&buffer.staging, data, index) or_return

  // Protect dirty_indices from concurrent access
  sync.mutex_lock(&buffer.dirty_mutex)
  defer sync.mutex_unlock(&buffer.dirty_mutex)
  interval_tree.insert(&buffer.dirty_indices, index, len(data))

  return .SUCCESS
}

// Generic write interface for staged buffers
staged_buffer_write :: proc {
  staged_buffer_write_single,
  staged_buffer_write_multi,
}

// Get element from staging buffer (CPU-side data)
staged_buffer_get :: proc(buffer: ^StagedBuffer($T), index: u32 = 0) -> ^T {
  return data_buffer_get(&buffer.staging, index)
}

// Get all elements from staging buffer as slice
staged_buffer_get_all :: proc(buffer: ^StagedBuffer($T)) -> []T {
  return data_buffer_get_all(&buffer.staging)
}

// Mark a range as dirty without writing data
staged_buffer_mark_dirty :: proc(
  buffer: ^StagedBuffer($T),
  start_index: int,
  count: int,
) {
  // Protect dirty_indices from concurrent access
  sync.mutex_lock(&buffer.dirty_mutex)
  defer sync.mutex_unlock(&buffer.dirty_mutex)
  interval_tree.insert(&buffer.dirty_indices, start_index, count)
}

// Get offset for a specific index in the buffer
staged_buffer_offset_of :: proc(buffer: ^StagedBuffer($T), index: u32) -> u32 {
  return data_buffer_offset_of(&buffer.staging, index)
}

// Destroy staged buffer and free all resources
staged_buffer_destroy :: proc(device: vk.Device, buffer: ^StagedBuffer($T)) {
  data_buffer_destroy(device, &buffer.staging)
  vk.DestroyBuffer(device, buffer.device_buffer, nil)
  buffer.device_buffer = 0
  vk.FreeMemory(device, buffer.device_memory, nil)
  buffer.device_memory = 0
  interval_tree.destroy(&buffer.dirty_indices)
  // Mutex doesn't need explicit destruction in Odin
}

malloc_image_buffer :: proc(
  gpu_context: ^GPUContext,
  width, height: u32,
  format: vk.Format,
  tiling: vk.ImageTiling,
  usage: vk.ImageUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
) -> (
  img_buffer: ImageBuffer,
  ret: vk.Result,
) {
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {width, height, 1},
    mipLevels     = 1,
    arrayLayers   = 1,
    format        = format,
    tiling        = tiling,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
  }
  vk.CreateImage(
    gpu_context.device,
    &create_info,
    nil,
    &img_buffer.image,
  ) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(
    gpu_context.device,
    img_buffer.image,
    &mem_reqs,
  )
  img_buffer.memory = allocate_vulkan_memory(
    gpu_context,
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindImageMemory(
    gpu_context.device,
    img_buffer.image,
    img_buffer.memory,
    0,
  ) or_return
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = format
  return img_buffer, .SUCCESS
}

ImageBuffer :: struct {
  image:         vk.Image,
  memory:        vk.DeviceMemory,
  width, height: u32,
  format:        vk.Format,
  view:          vk.ImageView,
}

image_buffer_destroy :: proc(device: vk.Device, self: ^ImageBuffer) {
  vk.DestroyImageView(device, self.view, nil)
  self.view = 0
  vk.DestroyImage(device, self.image, nil)
  self.image = 0
  vk.FreeMemory(device, self.memory, nil)
  self.memory = 0
  self.width = 0
  self.height = 0
  self.format = .UNDEFINED
}

create_image_view :: proc(
  device: vk.Device,
  image: vk.Image,
  format: vk.Format,
  aspect_mask: vk.ImageAspectFlags,
) -> (
  view: vk.ImageView,
  res: vk.Result,
) {
  create_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = image,
    viewType = .D2,
    format = format,
    components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
    subresourceRange = {
      aspectMask = aspect_mask,
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  res = vk.CreateImageView(device, &create_info, nil, &view)
  return
}

transition_image_layout :: proc(
  gpu_context: ^GPUContext,
  image: vk.Image,
  format: vk.Format,
  old_layout, new_layout: vk.ImageLayout,
) -> vk.Result {
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  src_access_mask: vk.AccessFlags
  dst_access_mask: vk.AccessFlags
  src_stage: vk.PipelineStageFlags
  dst_stage: vk.PipelineStageFlags
  if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
    dst_access_mask = {.TRANSFER_WRITE}
    src_stage = {.TOP_OF_PIPE}
    dst_stage = {.TRANSFER}
  } else if old_layout == .TRANSFER_DST_OPTIMAL &&
     new_layout == .SHADER_READ_ONLY_OPTIMAL {
    src_access_mask = {.TRANSFER_WRITE}
    dst_access_mask = {.SHADER_READ}
    src_stage = {.TRANSFER}
    dst_stage = {.FRAGMENT_SHADER}
  } else {
    // Fallback: generic, but not optimal
    src_stage = {.TOP_OF_PIPE}
    dst_stage = {.TOP_OF_PIPE}
  }
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = new_layout,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = src_access_mask,
    dstAccessMask = dst_access_mask,
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  return end_single_time_command(gpu_context, &cmd_buffer)
}

copy_image :: proc(
  gpu_context: ^GPUContext,
  dst: ImageBuffer,
  src: DataBuffer(u8),
) -> vk.Result {
  transition_image_layout(
    gpu_context,
    dst.image,
    dst.format,
    .UNDEFINED,
    .TRANSFER_DST_OPTIMAL,
  ) or_return
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  region := vk.BufferImageCopy {
    bufferOffset = 0,
    bufferRowLength = 0,
    bufferImageHeight = 0,
    imageSubresource = {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    imageOffset = {0, 0, 0},
    imageExtent = {dst.width, dst.height, 1},
  }
  vk.CmdCopyBufferToImage(
    cmd_buffer,
    src.buffer,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )
  end_single_time_command(gpu_context, &cmd_buffer) or_return
  transition_image_layout(
    gpu_context,
    dst.image,
    dst.format,
    .TRANSFER_DST_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
  ) or_return
  return .SUCCESS
}

// Copy image but leave in TRANSFER_DST_OPTIMAL for mip generation
copy_image_for_mips :: proc(
  gpu_context: ^GPUContext,
  dst: ImageBuffer,
  src: DataBuffer(u8),
) -> vk.Result {
  transition_image_layout(
    gpu_context,
    dst.image,
    dst.format,
    .UNDEFINED,
    .TRANSFER_DST_OPTIMAL,
  ) or_return
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  region := vk.BufferImageCopy {
    bufferOffset = 0,
    bufferRowLength = 0,
    bufferImageHeight = 0,
    imageSubresource = {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    imageOffset = {0, 0, 0},
    imageExtent = {dst.width, dst.height, 1},
  }
  vk.CmdCopyBufferToImage(
    cmd_buffer,
    src.buffer,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )
  end_single_time_command(gpu_context, &cmd_buffer) or_return
  // Don't transition to SHADER_READ_ONLY - leave in TRANSFER_DST_OPTIMAL for mip generation
  return .SUCCESS
}

create_image_buffer :: proc(
  gpu_context: ^GPUContext,
  data: rawptr,
  size: vk.DeviceSize,
  format: vk.Format,
  width, height: u32,
) -> (
  img: ImageBuffer,
  ret: vk.Result,
) {
  staging := create_host_visible_buffer(
    gpu_context,
    u8,
    int(size),
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer data_buffer_destroy(gpu_context.device, &staging)
  img = malloc_image_buffer(
    gpu_context,
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  copy_image(gpu_context, img, staging) or_return
  aspect_mask := vk.ImageAspectFlags{.COLOR}
  img.view = create_image_view(
    gpu_context.device,
    img.image,
    format,
    aspect_mask,
  ) or_return
  ret = .SUCCESS
  return
}
depth_image_init :: proc(
  gpu_context: ^GPUContext,
  img_buffer: ^ImageBuffer,
  width, height: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT},
) -> vk.Result {
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = format
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {width, height, 1},
    mipLevels     = 1,
    arrayLayers   = 1,
    format        = img_buffer.format,
    tiling        = .OPTIMAL,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
  }
  vk.CreateImage(
    gpu_context.device,
    &create_info,
    nil,
    &img_buffer.image,
  ) or_return
  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(
    gpu_context.device,
    img_buffer.image,
    &mem_requirements,
  )
  memory_type_index, found := find_memory_type_index(
    gpu_context,
    mem_requirements.memoryTypeBits,
    {.DEVICE_LOCAL},
  )
  if !found {
    return .ERROR_UNKNOWN
  }
  alloc_info := vk.MemoryAllocateInfo {
    sType           = .MEMORY_ALLOCATE_INFO,
    allocationSize  = mem_requirements.size,
    memoryTypeIndex = memory_type_index,
  }
  vk.AllocateMemory(
    gpu_context.device,
    &alloc_info,
    nil,
    &img_buffer.memory,
  ) or_return
  vk.BindImageMemory(
    gpu_context.device,
    img_buffer.image,
    img_buffer.memory,
    0,
  )
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = .UNDEFINED,
    newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = img_buffer.image,
    subresourceRange = {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = {}, // No source access needed for UNDEFINED -> WRITE
    dstAccessMask = {
      .DEPTH_STENCIL_ATTACHMENT_READ,
      .DEPTH_STENCIL_ATTACHMENT_WRITE,
    },
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS}, // Corrected enum value (or LATE_FRAGMENT_TESTS depending on usage)
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  end_single_time_command(gpu_context, &cmd_buffer) or_return
  img_buffer.view = create_image_view(
    gpu_context.device,
    img_buffer.image,
    img_buffer.format,
    {.DEPTH},
  ) or_return
  return .SUCCESS
}

CubeImageBuffer :: struct {
  using buffer: ImageBuffer,
  face_views:   [6]vk.ImageView, // One view per face for rendering
}

cube_depth_texture_init :: proc(
  gpu_context: ^GPUContext,
  self: ^CubeImageBuffer,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> vk.Result {
  self.width = size
  self.height = size
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {size, size, 1},
    mipLevels     = 1,
    arrayLayers   = 6,
    format        = .D32_SFLOAT,
    tiling        = .OPTIMAL,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
    flags         = {.CUBE_COMPATIBLE},
  }
  vk.CreateImage(gpu_context.device, &create_info, nil, &self.image) or_return
  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(
    gpu_context.device,
    self.image,
    &mem_requirements,
  )
  memory_type_index, found := find_memory_type_index(
    gpu_context,
    mem_requirements.memoryTypeBits,
    {.DEVICE_LOCAL},
  )
  if !found {
    return .ERROR_UNKNOWN
  }
  alloc_info := vk.MemoryAllocateInfo {
    sType           = .MEMORY_ALLOCATE_INFO,
    allocationSize  = mem_requirements.size,
    memoryTypeIndex = memory_type_index,
  }
  vk.AllocateMemory(
    gpu_context.device,
    &alloc_info,
    nil,
    &self.memory,
  ) or_return
  vk.BindImageMemory(gpu_context.device, self.image, self.memory, 0)
  // Create 6 image views (one per face)
  for i in 0 ..< 6 {
    view_info := vk.ImageViewCreateInfo {
      sType = .IMAGE_VIEW_CREATE_INFO,
      image = self.image,
      viewType = .D2,
      format = .D32_SFLOAT,
      components = {
        r = .IDENTITY,
        g = .IDENTITY,
        b = .IDENTITY,
        a = .IDENTITY,
      },
      subresourceRange = {
        aspectMask = {.DEPTH},
        baseMipLevel = 0,
        levelCount = 1,
        baseArrayLayer = u32(i),
        layerCount = 1,
      },
    }
    vk.CreateImageView(
      gpu_context.device,
      &view_info,
      nil,
      &self.face_views[i],
    ) or_return
  }
  cube_view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = self.image,
    viewType = .CUBE,
    format = .D32_SFLOAT,
    components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
    subresourceRange = {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 6,
    },
  }
  vk.CreateImageView(
    gpu_context.device,
    &cube_view_info,
    nil,
    &self.view,
  ) or_return
  return .SUCCESS
}

cube_depth_texture_destroy :: proc(device: vk.Device, self: ^CubeImageBuffer) {
  if self == nil {
    return
  }
  for &v in self.face_views {
    vk.DestroyImageView(device, v, nil)
    v = 0
  }
  vk.DestroyImageView(device, self.view, nil)
  self.view = 0
  image_buffer_destroy(device, &self.buffer)
}

// Create image buffer with custom mip levels
malloc_image_buffer_with_mips :: proc(
  gpu_context: ^GPUContext,
  width, height: u32,
  format: vk.Format,
  tiling: vk.ImageTiling,
  usage: vk.ImageUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
  mip_levels: u32,
) -> (
  img_buffer: ImageBuffer,
  ret: vk.Result,
) {
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {width, height, 1},
    mipLevels     = mip_levels,
    arrayLayers   = 1,
    format        = format,
    tiling        = tiling,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
  }
  vk.CreateImage(
    gpu_context.device,
    &create_info,
    nil,
    &img_buffer.image,
  ) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(
    gpu_context.device,
    img_buffer.image,
    &mem_reqs,
  )
  img_buffer.memory = allocate_vulkan_memory(
    gpu_context,
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindImageMemory(
    gpu_context.device,
    img_buffer.image,
    img_buffer.memory,
    0,
  ) or_return
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = format
  return img_buffer, .SUCCESS
}

// Create image view with mip levels
create_image_view_with_mips :: proc(
  device: vk.Device,
  image: vk.Image,
  format: vk.Format,
  aspect: vk.ImageAspectFlags,
  mip_levels: u32,
) -> (
  view: vk.ImageView,
  ret: vk.Result,
) {
  log.infof("Creating image view with %d mip levels", mip_levels)
  create_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = image,
    viewType = .D2,
    format = format,
    subresourceRange = {
      aspectMask = aspect,
      baseMipLevel = 0,
      levelCount = mip_levels,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  vk.CreateImageView(device, &create_info, nil, &view) or_return
  log.infof(
    "Image view created successfully with mip levels 0-%d",
    mip_levels - 1,
  )
  return view, .SUCCESS
}

// Generate mip maps for an image
generate_mipmaps :: proc(
  gpu_context: ^GPUContext,
  img: ImageBuffer,
  format: vk.Format,
  tex_width, tex_height: u32,
  mip_levels: u32,
) -> vk.Result {
  format_props: vk.FormatProperties
  vk.GetPhysicalDeviceFormatProperties(
    gpu_context.physical_device,
    format,
    &format_props,
  )
  if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
    log.errorf("Texture image format does not support linear blitting!")
    return .ERROR_UNKNOWN
  }
  cmd_buffer := begin_single_time_command(gpu_context) or_return
  defer end_single_time_command(gpu_context, &cmd_buffer)

  // First, transition all mip levels from UNDEFINED to TRANSFER_DST_OPTIMAL
  init_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    image = img.image,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    oldLayout = .UNDEFINED,
    newLayout = .TRANSFER_DST_OPTIMAL,
    srcAccessMask = {},
    dstAccessMask = {.TRANSFER_WRITE},
    subresourceRange = {
      aspectMask = {.COLOR},
      baseArrayLayer = 0,
      layerCount = 1,
      baseMipLevel = 0,
      levelCount = mip_levels,
    },
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TOP_OF_PIPE},
    {.TRANSFER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &init_barrier,
  )

  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    image = img.image,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseArrayLayer = 0,
      layerCount = 1,
      levelCount = 1,
    },
  }
  mip_width := i32(tex_width)
  mip_height := i32(tex_height)
  for i in 1 ..< mip_levels {
    barrier.subresourceRange.baseMipLevel = i - 1
    barrier.oldLayout = .TRANSFER_DST_OPTIMAL
    barrier.newLayout = .TRANSFER_SRC_OPTIMAL
    barrier.srcAccessMask = {.TRANSFER_WRITE}
    barrier.dstAccessMask = {.TRANSFER_READ}
    vk.CmdPipelineBarrier(
      cmd_buffer,
      {.TRANSFER},
      {.TRANSFER},
      {},
      0,
      nil,
      0,
      nil,
      1,
      &barrier,
    )
    blit := vk.ImageBlit {
      srcOffsets = {{0, 0, 0}, {mip_width, mip_height, 1}},
      srcSubresource = {
        aspectMask = {.COLOR},
        mipLevel = i - 1,
        baseArrayLayer = 0,
        layerCount = 1,
      },
      dstOffsets = {
        {0, 0, 0},
        {max(mip_width / 2, 1), max(mip_height / 2, 1), 1},
      },
      dstSubresource = {
        aspectMask = {.COLOR},
        mipLevel = i,
        baseArrayLayer = 0,
        layerCount = 1,
      },
    }
    vk.CmdBlitImage(
      cmd_buffer,
      img.image,
      .TRANSFER_SRC_OPTIMAL,
      img.image,
      .TRANSFER_DST_OPTIMAL,
      1,
      &blit,
      .LINEAR,
    )
    barrier.oldLayout = .TRANSFER_SRC_OPTIMAL
    barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
    barrier.srcAccessMask = {.TRANSFER_READ}
    barrier.dstAccessMask = {.SHADER_READ}
    vk.CmdPipelineBarrier(
      cmd_buffer,
      {.TRANSFER},
      {.FRAGMENT_SHADER},
      {},
      0,
      nil,
      0,
      nil,
      1,
      &barrier,
    )
    mip_width = max(mip_width / 2, 1)
    mip_height = max(mip_height / 2, 1)
  }
  // Mip generation complete
  barrier.subresourceRange.baseMipLevel = mip_levels - 1
  barrier.oldLayout = .TRANSFER_DST_OPTIMAL
  barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
  barrier.srcAccessMask = {.TRANSFER_WRITE}
  barrier.dstAccessMask = {.SHADER_READ}
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TRANSFER},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  return .SUCCESS
}

transition_vk_images :: proc(
  command_buffer: vk.CommandBuffer,
  images: []vk.Image,
  old_layout: vk.ImageLayout,
  new_layout: vk.ImageLayout,
  aspect_mask: vk.ImageAspectFlags,
  layer_count: u32,
  src_stage: vk.PipelineStageFlags,
  dst_stage: vk.PipelineStageFlags,
  dst_access_mask: vk.AccessFlags,
) {
  barriers := make(
    []vk.ImageMemoryBarrier,
    len(images),
    context.temp_allocator,
  )
  for image, i in images {
    barriers[i] = vk.ImageMemoryBarrier {
      sType = .IMAGE_MEMORY_BARRIER,
      oldLayout = old_layout,
      newLayout = new_layout,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = image,
      subresourceRange = {
        aspectMask = aspect_mask,
        levelCount = 1,
        layerCount = layer_count,
      },
      dstAccessMask = dst_access_mask,
    }
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    0,
    nil,
    u32(len(barriers)),
    raw_data(barriers),
  )
}

transition_vk_image :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
  old_layout: vk.ImageLayout,
  new_layout: vk.ImageLayout,
  aspect_mask: vk.ImageAspectFlags,
  src_stage: vk.PipelineStageFlags,
  dst_stage: vk.PipelineStageFlags,
  src_access_mask: vk.AccessFlags = {},
  dst_access_mask: vk.AccessFlags = {},
  base_mip_level: u32 = 0,
  level_count: u32 = 1,
  base_array_layer: u32 = 0,
  layer_count: u32 = 1,
) {
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = new_layout,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {
      aspectMask = aspect_mask,
      baseMipLevel = base_mip_level,
      levelCount = level_count,
      baseArrayLayer = base_array_layer,
      layerCount = layer_count,
    },
    srcAccessMask = src_access_mask,
    dstAccessMask = dst_access_mask,
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
}

transition_2d_images :: proc(
  command_buffer: vk.CommandBuffer,
  images: []ImageBuffer,
  old_layout: vk.ImageLayout,
  new_layout: vk.ImageLayout,
  aspect_mask: vk.ImageAspectFlags,
  layer_count: u32,
  src_stage: vk.PipelineStageFlags,
  dst_stage: vk.PipelineStageFlags,
  dst_access_mask: vk.AccessFlags,
) {
  barriers := make(
    []vk.ImageMemoryBarrier,
    len(images),
    context.temp_allocator,
  )
  for texture, i in images {
    barriers[i] = vk.ImageMemoryBarrier {
      sType = .IMAGE_MEMORY_BARRIER,
      oldLayout = old_layout,
      newLayout = new_layout,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = texture.image,
      subresourceRange = {
        aspectMask = aspect_mask,
        levelCount = 1,
        layerCount = layer_count,
      },
      dstAccessMask = dst_access_mask,
    }
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    0,
    nil,
    u32(len(barriers)),
    raw_data(barriers),
  )
}

transition_cube_images :: proc(
  command_buffer: vk.CommandBuffer,
  images: []CubeImageBuffer,
  old_layout: vk.ImageLayout,
  new_layout: vk.ImageLayout,
  aspect_mask: vk.ImageAspectFlags,
  layer_count: u32,
  src_stage: vk.PipelineStageFlags,
  dst_stage: vk.PipelineStageFlags,
  dst_access_mask: vk.AccessFlags,
) {
  barriers := make(
    []vk.ImageMemoryBarrier,
    len(images),
    context.temp_allocator,
  )
  for texture, i in images {
    barriers[i] = vk.ImageMemoryBarrier {
      sType = .IMAGE_MEMORY_BARRIER,
      oldLayout = old_layout,
      newLayout = new_layout,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = texture.image,
      subresourceRange = {
        aspectMask = aspect_mask,
        levelCount = 1,
        layerCount = layer_count,
      },
      dstAccessMask = dst_access_mask,
    }
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    0,
    nil,
    u32(len(barriers)),
    raw_data(barriers),
  )
}

transition_image_to_shader_read :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
  old_layout: vk.ImageLayout = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
) {
  transition_image(
    command_buffer,
    image,
    old_layout,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ},
  )
}

transition_image_to_present :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
) {
  transition_image(
    command_buffer,
    image,
    .COLOR_ATTACHMENT_OPTIMAL,
    .PRESENT_SRC_KHR,
    {.COLOR},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.BOTTOM_OF_PIPE},
    {.COLOR_ATTACHMENT_WRITE},
    {},
  )
}

transition_images :: proc {
  transition_2d_images,
  transition_cube_images,
  transition_vk_images,
}

transition_image :: proc {
  transition_vk_image,
}
