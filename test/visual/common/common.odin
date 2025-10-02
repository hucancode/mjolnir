package visual

import "core:log"
import "core:math"
import "core:time"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "vendor:glfw"

ColorMode :: enum {
  CONSTANT,
  CHECKER,
  GRADIENT,
}

VisualTestConfig :: struct {
  name:             string,
  grid_dims:        [2]int,
  spacing:          f32,
  cube_scale:       f32,
  base_color:       [4]f32,
  accent_color:     [4]f32,
  color_mode:       ColorMode,
  window_width:     u32,
  window_height:    u32,
  run_seconds:      f32,
  camera_position:  [3]f32,
  camera_target:    [3]f32,
  camera_fov:       f32,
  camera_near:      f32,
  camera_far:       f32,
  enable_shadows:   bool,
}

visual_state: VisualTestState

ChunkMesh :: struct {
  width:  int,
  height: int,
  handle: resources.Handle,
}

VisualTestState :: struct {
  config:          VisualTestConfig,
  mesh_handles:    [dynamic]ChunkMesh,
  node_handles:    [dynamic]resources.Handle,
  material_handle: resources.Handle,
  start_time:      time.Time,
}

CHUNK_DIMENSION :: 32

run_visual_test :: proc(config: VisualTestConfig) -> bool {
  if config.grid_dims[0] <= 0 || config.grid_dims[1] <= 0 {
    return false
  }
  if visual_state.mesh_handles != nil {
    delete(visual_state.mesh_handles)
  }
  if visual_state.node_handles != nil {
    delete(visual_state.node_handles)
  }
  visual_state = VisualTestState{config = config}
  visual_state.mesh_handles = make([dynamic]ChunkMesh, 0)
  visual_state.node_handles = make([dynamic]resources.Handle, 0)
  if visual_state.config.run_seconds <= 0 {
    visual_state.config.run_seconds = 3.0
  }
  if visual_state.config.spacing <= 0 {
    visual_state.config.spacing = 1.5
  }
  if visual_state.config.cube_scale <= 0 {
    visual_state.config.cube_scale = 0.5
  }
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, config.window_width, config.window_height, config.name)
  return true
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  cfg := &visual_state.config
  mat_handle, mat_ok := resources.create_material_handle(
    &engine.resource_manager,
    type = resources.MaterialType.UNLIT,
    base_color_factor = cfg.base_color,
  )
  if !mat_ok {
    log.error("Failed to create visual test resources")
    return
  }
  visual_state.material_handle = mat_handle
  chunk_dim := choose_chunk_dimension(cfg)
  base_cube := geometry.make_cube()
  defer geometry.delete_geometry(base_cube)
  columns := cfg.grid_dims[0]
  rows := cfg.grid_dims[1]
  for z_start := 0; z_start < rows; z_start += chunk_dim {
    current_rows := chunk_dim
    remaining_rows := rows - z_start
    if remaining_rows < current_rows {
      current_rows = remaining_rows
    }
    for x_start := 0; x_start < columns; x_start += chunk_dim {
      current_cols := chunk_dim
      remaining_cols := columns - x_start
      if remaining_cols < current_cols {
        current_cols = remaining_cols
      }
      chunk_center := compute_chunk_center(cfg, x_start, current_cols, z_start, current_rows)
      mesh_handle, mesh_ok := get_or_create_chunk_mesh(
        engine,
        &base_cube,
        cfg,
        x_start,
        z_start,
        current_cols,
        current_rows,
      )
      if !mesh_ok {
        log.error("Failed to create mesh chunk")
        return
      }
      attachment := world.MeshAttachment {
        handle = mesh_handle,
        material = mat_handle,
        cast_shadow = cfg.enable_shadows,
      }
      handle, node, spawned := world.spawn(
        &engine.world,
        attachment,
        &engine.resource_manager,
      )
      if !spawned {
        log.error("Failed to spawn visual test mesh chunk")
        return
      }
      world.translate(node, chunk_center.x, chunk_center.y, chunk_center.z)
      append(&visual_state.node_handles, handle)
    }
  }
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    geometry.camera_perspective(
      camera,
      cfg.camera_fov,
      f32(cfg.window_width) / f32(cfg.window_height),
      cfg.camera_near,
      cfg.camera_far,
    )
    geometry.camera_look_at(camera, cfg.camera_position, cfg.camera_target)
  }
  visual_state.start_time = time.now()
}

update_scene :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  _ = delta_time
  cfg := &visual_state.config
  elapsed := f32(time.duration_seconds(time.since(visual_state.start_time)))
  if elapsed >= cfg.run_seconds {
    glfw.SetWindowShouldClose(engine.window, true)
  }
}

choose_chunk_dimension :: proc(cfg: ^VisualTestConfig) -> int {
  max_dim := cfg.grid_dims[0]
  if cfg.grid_dims[1] > max_dim {
    max_dim = cfg.grid_dims[1]
  }
  if max_dim <= CHUNK_DIMENSION {
    if max_dim <= 0 {
      return 1
    }
    return max_dim
  }
  return CHUNK_DIMENSION
}

compute_chunk_center :: proc(
  cfg: ^VisualTestConfig,
  x_start, chunk_cols: int,
  z_start, chunk_rows: int,
) -> [3]f32 {
  half_cols := (f32(cfg.grid_dims[0]) - 1.0) * 0.5
  half_rows := (f32(cfg.grid_dims[1]) - 1.0) * 0.5
  chunk_half_cols := (f32(chunk_cols) - 1.0) * 0.5
  chunk_half_rows := (f32(chunk_rows) - 1.0) * 0.5
  center_x := ((f32(x_start) + chunk_half_cols) - half_cols) * cfg.spacing
  center_z := ((f32(z_start) + chunk_half_rows) - half_rows) * cfg.spacing
  return [3]f32{center_x, 0.0, center_z}
}

get_or_create_chunk_mesh :: proc(
  engine: ^mjolnir.Engine,
  base_cube: ^geometry.Geometry,
  cfg: ^VisualTestConfig,
  x_start, z_start: int,
  chunk_cols, chunk_rows: int,
) -> (handle: resources.Handle, ok: bool) {
  use_cache := cfg.color_mode == .CONSTANT
  if use_cache {
    for entry in visual_state.mesh_handles {
      if entry.width == chunk_cols && entry.height == chunk_rows {
        return entry.handle, true
      }
    }
  }
  chunk := build_cube_chunk_geometry(
    cfg,
    base_cube,
    x_start,
    z_start,
    chunk_cols,
    chunk_rows,
  )
  handle, ok = resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    chunk,
  )
  if !ok {
    return resources.Handle{}, false
  }
  append(
    &visual_state.mesh_handles,
    ChunkMesh{width = chunk_cols, height = chunk_rows, handle = handle},
  )
  return handle, true
}

build_cube_chunk_geometry :: proc(
  cfg: ^VisualTestConfig,
  base_cube: ^geometry.Geometry,
  x_start, z_start: int,
  chunk_cols, chunk_rows: int,
) -> geometry.Geometry {
  vertex_per_cube := len(base_cube.vertices)
  index_per_cube := len(base_cube.indices)
  cube_count := chunk_cols * chunk_rows
  geom := geometry.Geometry{}
  geom.vertices = make([]geometry.Vertex, cube_count * vertex_per_cube)
  geom.indices = make([]u32, cube_count * index_per_cube)
  chunk_half_x := (f32(chunk_cols) - 1.0) * 0.5
  chunk_half_z := (f32(chunk_rows) - 1.0) * 0.5
  cube_index := 0
  for local_z in 0 ..< chunk_rows {
    global_z := z_start + local_z
    for local_x in 0 ..< chunk_cols {
      global_x := x_start + local_x
      color := choose_color(cfg, global_x, global_z)
      offset := [3]f32 {
        (f32(local_x) - chunk_half_x) * cfg.spacing,
        0.0,
        (f32(local_z) - chunk_half_z) * cfg.spacing,
      }
      write_cube_geometry(
        &geom,
        cube_index,
        base_cube,
        offset,
        cfg.cube_scale,
        color,
      )
      cube_index += 1
    }
  }
  extent_x := chunk_half_x * cfg.spacing + cfg.cube_scale
  extent_z := chunk_half_z * cfg.spacing + cfg.cube_scale
  geom.aabb.min = {-extent_x, -cfg.cube_scale, -extent_z}
  geom.aabb.max = {extent_x, cfg.cube_scale, extent_z}
  return geom
}

choose_color :: proc(cfg: ^VisualTestConfig, x, z: int) -> [4]f32 {
  switch cfg.color_mode {
  case .CONSTANT:
    return cfg.base_color
  case .CHECKER:
    if (x + z) % 2 == 0 do return cfg.base_color
    return cfg.accent_color
  case .GRADIENT:
    fx := f32(x)
    fz := f32(z)
    denom_x := f32(cfg.grid_dims[0] - 1)
    denom_z := f32(cfg.grid_dims[1] - 1)
    if denom_x <= 0 do denom_x = 1.0
    if denom_z <= 0 do denom_z = 1.0
    nx := fx / denom_x
    nz := fz / denom_z
    return [4]f32 {
      math.lerp(cfg.base_color.r, cfg.accent_color.r, nx),
      math.lerp(cfg.base_color.g, cfg.accent_color.g, nz),
      math.lerp(cfg.base_color.b, cfg.accent_color.b, (nx + nz) * 0.5),
      cfg.base_color.a,
    }
  }
  return cfg.base_color
}

write_cube_geometry :: proc(
  geom: ^geometry.Geometry,
  cube_index: int,
  source: ^geometry.Geometry,
  offset: [3]f32,
  scale: f32,
  color: [4]f32,
) {
  vertex_per_cube := len(source.vertices)
  index_per_cube := len(source.indices)
  vertex_offset := cube_index * vertex_per_cube
  index_offset := cube_index * index_per_cube
  for i in 0 ..< vertex_per_cube {
    src := source.vertices[i]
    dst := &geom.vertices[vertex_offset + i]
    dst.position = [3]f32 {
      src.position.x * scale + offset.x,
      src.position.y * scale + offset.y,
      src.position.z * scale + offset.z,
    }
    dst.normal = src.normal
    dst.color = color
    dst.uv = src.uv
    dst.tangent = src.tangent
  }
  for i in 0 ..< index_per_cube {
    geom.indices[index_offset + i] = source.indices[i] + u32(vertex_offset)
  }
}
