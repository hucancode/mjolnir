package mjolnir

import "gpu"

// Re-export GPU types for backward compatibility
DataBuffer :: gpu.DataBuffer
ImageBuffer :: gpu.ImageBuffer
CubeImageBuffer :: gpu.CubeImageBuffer
GPUContext :: gpu.GPUContext

// Re-export constants
MAX_SAMPLERS :: gpu.MAX_SAMPLERS

// Re-export memory functions
data_buffer_get :: gpu.data_buffer_get
data_buffer_get_all :: gpu.data_buffer_get_all
data_buffer_write :: gpu.data_buffer_write
data_buffer_deinit :: gpu.data_buffer_deinit
data_buffer_offset_of :: gpu.data_buffer_offset_of
create_host_visible_buffer :: gpu.create_host_visible_buffer
create_local_buffer :: gpu.create_local_buffer
malloc_image_buffer :: gpu.malloc_image_buffer
create_image_buffer :: gpu.create_image_buffer
image_buffer_deinit :: gpu.image_buffer_deinit
cube_depth_texture_init :: gpu.cube_depth_texture_init
cube_depth_texture_deinit :: gpu.cube_depth_texture_deinit
create_image_view :: gpu.create_image_view
malloc_image_buffer_with_mips :: gpu.malloc_image_buffer_with_mips
copy_image_for_mips :: gpu.copy_image_for_mips
generate_mipmaps :: gpu.generate_mipmaps
create_image_view_with_mips :: gpu.create_image_view_with_mips
transition_image :: gpu.transition_image
transition_images :: gpu.transition_images
transition_image_to_shader_read :: gpu.transition_image_to_shader_read
transition_image_to_present :: gpu.transition_image_to_present
query_swapchain_support :: gpu.query_swapchain_support
swapchain_support_deinit :: gpu.swapchain_support_deinit
create_shader_module :: gpu.create_shader_module