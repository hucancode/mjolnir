package mjolnir

import "gpu"
import "world"

load_gltf :: proc(
  engine: ^Engine,
  path: string,
) -> (
  nodes: [dynamic]world.NodeHandle,
  ok: bool,
) #optional_ok {
  create_texture_from_data_adapter := proc(
    pixel_data: []u8,
  ) -> (
    handle: gpu.Texture2DHandle,
    ok: bool,
  ) {
    engine_ctx := cast(^Engine)context.user_ptr
    if engine_ctx == nil {
      return {}, false
    }
    out_handle, ret := gpu.create_texture_2d_from_data(
      &engine_ctx.gctx,
      &engine_ctx.render.texture_manager,
      pixel_data,
      .R8G8B8A8_UNORM,
    )
    if ret != .SUCCESS {
      return {}, false
    }
    return out_handle, true
  }
  old_user_ptr := context.user_ptr
  context.user_ptr = engine
  defer context.user_ptr = old_user_ptr
  handles, result := world.load_gltf(
    &engine.world,
    create_texture_from_data_adapter,
    path,
  )
  return handles, result == .success
}
