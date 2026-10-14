#+private
package render

import vulkan "vulkan"

// The internal half of the backend boundary (see backend.odin).
when RENDER_BACKEND == "vulkan" {
  Backend :: vulkan.Backend
  MAX_NODES_IN_SCENE :: vulkan.MAX_NODES_IN_SCENE
  MAX_ACTIVE_CAMERAS :: vulkan.MAX_ACTIVE_CAMERAS
  RETIRE_GRACE :: vulkan.RETIRE_GRACE
  MAX_SHADOW_MAPS :: vulkan.MAX_SHADOW_MAPS
  SHADOW_MAP_SIZE :: vulkan.SHADOW_MAP_SIZE
  MAX_PARTICLES :: vulkan.MAX_PARTICLES
  MAX_TEXTURES :: vulkan.MAX_TEXTURES
  CAMERA_VIEW_BASE :: vulkan.CAMERA_VIEW_BASE
  SHADOW_VIEW_BASE :: vulkan.SHADOW_VIEW_BASE
  MAX_VIEWS :: vulkan.MAX_VIEWS
  MAX_PYRAMID_SLOTS :: vulkan.MAX_PYRAMID_SLOTS
  MAX_SHADOW_VIEWS :: vulkan.MAX_SHADOW_VIEWS
  MAX_DRAW_LIST_SLOTS :: vulkan.MAX_DRAW_LIST_SLOTS
  PREFILTER_MIPS :: vulkan.PREFILTER_MIPS
  MAX_SEGMENTS :: vulkan.MAX_SEGMENTS
  DEBUG_RING :: vulkan.DEBUG_RING
  TextureDesc :: vulkan.TextureDesc
  HDR_COLOR_FORMAT :: vulkan.HDR_COLOR_FORMAT
  ATTACHMENTS :: vulkan.ATTACHMENTS
  FIRST_FORWARD_TYPE :: vulkan.FIRST_FORWARD_TYPE
  Table :: vulkan.Table
  MeshStream :: vulkan.MeshStream
  MeshData :: vulkan.MeshData
  ParticleSystemParams :: vulkan.ParticleSystemParams
  PostPass :: vulkan.PostPass
  UIBatch :: vulkan.UIBatch
  FrameCamera :: vulkan.FrameCamera
  FrameDesc :: vulkan.FrameDesc

  backend_init :: vulkan.init
  backend_shutdown :: vulkan.shutdown
  backend_wait_idle :: vulkan.wait_idle
  backend_tick :: vulkan.tick
  backend_frame_serial :: vulkan.frame_serial
  backend_extent :: vulkan.extent
  backend_resize :: vulkan.resize
  backend_table :: vulkan.table
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
  backend_ui_memory :: vulkan.ui_memory
  backend_frame :: vulkan.frame
}
