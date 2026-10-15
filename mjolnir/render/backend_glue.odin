#+private
package render

import "rhi"
import vulkan "vulkan"
import wgpu "wgpu"

when RENDER_BACKEND == "vulkan" {
  Backend :: vulkan.Backend
  RETIRE_GRACE :: vulkan.RETIRE_GRACE
  MAX_PYRAMID_SLOTS :: vulkan.MAX_PYRAMID_SLOTS
  MAX_DRAW_LIST_SLOTS :: vulkan.MAX_DRAW_LIST_SLOTS

  backend_init :: vulkan.init
  backend_ready :: vulkan.ready
  backend_shutdown :: vulkan.shutdown
  backend_wait_idle :: vulkan.wait_idle
  backend_tick :: vulkan.tick
  backend_frame_serial :: vulkan.frame_serial
  backend_extent :: vulkan.extent
  backend_resize :: vulkan.resize
  backend_mesh_write :: vulkan.mesh_write
  backend_texture_create :: vulkan.texture_create
  backend_texture_destroy :: vulkan.texture_destroy
  backend_draw_list_create :: vulkan.draw_list_create
  backend_draw_list_destroy :: vulkan.draw_list_destroy
  backend_pyramid_create :: vulkan.pyramid_create
  backend_pyramid_destroy :: vulkan.pyramid_destroy
  backend_precompute_ibl :: vulkan.precompute_ibl
  backend_particles_reset :: vulkan.particles_reset
  backend_draw_count :: vulkan.draw_count
  backend_caps :: vulkan.rhi_caps
  backend_frame :: vulkan.frame
} else when RENDER_BACKEND == "wgpu" {
  Backend :: wgpu.Backend
  RETIRE_GRACE :: wgpu.RETIRE_GRACE
  MAX_PYRAMID_SLOTS :: wgpu.MAX_PYRAMID_SLOTS
  MAX_DRAW_LIST_SLOTS :: wgpu.MAX_DRAW_LIST_SLOTS

  backend_init :: wgpu.init
  backend_ready :: wgpu.ready
  backend_shutdown :: wgpu.shutdown
  backend_wait_idle :: wgpu.wait_idle
  backend_tick :: wgpu.tick
  backend_frame_serial :: wgpu.frame_serial
  backend_extent :: wgpu.extent
  backend_resize :: wgpu.resize
  backend_mesh_write :: wgpu.mesh_write
  backend_texture_create :: wgpu.texture_create
  backend_texture_destroy :: wgpu.texture_destroy
  backend_draw_list_create :: wgpu.draw_list_create
  backend_draw_list_destroy :: wgpu.draw_list_destroy
  backend_pyramid_create :: wgpu.pyramid_create
  backend_pyramid_destroy :: wgpu.pyramid_destroy
  backend_precompute_ibl :: wgpu.precompute_ibl
  backend_particles_reset :: wgpu.particles_reset
  backend_draw_count :: wgpu.draw_count
  backend_caps :: wgpu.rhi_caps
  backend_frame :: wgpu.frame
}

MAX_NODES_IN_SCENE :: rhi.MAX_NODES_IN_SCENE
MAX_BATCHES :: rhi.MAX_BATCHES
MAX_ACTIVE_CAMERAS :: rhi.MAX_ACTIVE_CAMERAS
MAX_SHADOW_MAPS :: rhi.MAX_SHADOW_MAPS
SHADOW_MAP_SIZE :: rhi.SHADOW_MAP_SIZE
MAX_PARTICLES :: rhi.MAX_PARTICLES
MAX_TEXTURES :: rhi.MAX_TEXTURES
CAMERA_VIEW_BASE :: rhi.CAMERA_VIEW_BASE
SHADOW_VIEW_BASE :: rhi.SHADOW_VIEW_BASE
MAX_VIEWS :: rhi.MAX_VIEWS
MAX_SHADOW_VIEWS :: rhi.MAX_SHADOW_VIEWS
PREFILTER_MIPS :: rhi.PREFILTER_MIPS
MAX_SEGMENTS :: rhi.MAX_SEGMENTS
DEBUG_RING :: rhi.DEBUG_RING
TABLE_REGIONS :: rhi.TABLE_REGIONS
UI_MAX_VERTICES :: rhi.UI_MAX_VERTICES
UI_MAX_INDICES :: rhi.UI_MAX_INDICES
TextureDesc :: rhi.TextureDesc
HDR_COLOR_FORMAT :: rhi.HDR_COLOR_FORMAT
ATTACHMENTS :: rhi.ATTACHMENTS
FIRST_FORWARD_TYPE :: rhi.FIRST_FORWARD_TYPE
Table :: rhi.Table
MeshStream :: rhi.MeshStream
MeshData :: rhi.MeshData
ParticleSystemParams :: rhi.ParticleSystemParams
PostPass :: rhi.PostPass
UIBatch :: rhi.UIBatch
FrameCamera :: rhi.FrameCamera
FrameDesc :: rhi.FrameDesc
