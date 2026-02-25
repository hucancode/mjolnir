package render

import rg "graph"

SHADOW_COMPUTE_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.SHADOW_COMPUTE),
  scope   = .PER_LIGHT,
  queue   = .COMPUTE,
  inputs  = {},
  outputs = {
    rg.ResourceRefTemplate {
      index = .SHADOW_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

SHADOW_DEPTH_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.SHADOW_DEPTH),
  scope   = .PER_LIGHT,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .SHADOW_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

PARTICLE_SIMULATION_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.PARTICLE_SIMULATION),
  scope   = .GLOBAL,
  queue   = .COMPUTE,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .PARTICLE_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .PARTICLE_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .COMPACT_PARTICLE_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .DRAW_COMMAND_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
  },
}

VISIBILITY_CULLING_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.VISIBILITY_CULLING),
  scope   = .PER_CAMERA,
  queue   = .COMPUTE,
  inputs  = {},
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_OPAQUE_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_OPAQUE_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_TRANSPARENT_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_TRANSPARENT_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_WIREFRAME_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_WIREFRAME_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_RANDOM_COLOR_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_RANDOM_COLOR_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_LINE_STRIP_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_LINE_STRIP_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_SPRITE_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_SPRITE_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

DEPTH_PYRAMID_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.DEPTH_PYRAMID),
  scope   = .PER_CAMERA,
  queue   = .COMPUTE,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH_PYRAMID,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

DEPTH_PREPASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.DEPTH_PREPASS),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_OPAQUE_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_OPAQUE_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

GEOMETRY_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.GEOMETRY),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_OPAQUE_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_OPAQUE_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_POSITION,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_NORMAL,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_ALBEDO,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_METALLIC_ROUGHNESS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_EMISSIVE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

AMBIENT_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.AMBIENT),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_POSITION,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_NORMAL,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_ALBEDO,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_METALLIC_ROUGHNESS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_EMISSIVE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

DIRECT_LIGHT_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.DIRECT_LIGHT),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_POSITION,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_NORMAL,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_ALBEDO,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_METALLIC_ROUGHNESS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_GBUFFER_EMISSIVE,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 1},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 2},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 3},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 4},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 5},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 6},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 7},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 8},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 9},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 10},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 11},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 12},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 13},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 14},
    },
    rg.ResourceRefTemplate {
      index = .SHADOW_MAP,
      instance = rg.FixedResourceTemplate{scope_index = 15},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

PARTICLES_RENDER_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.PARTICLES_RENDER),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .COMPACT_PARTICLE_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .DRAW_COMMAND_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

TRANSPARENT_RENDER_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.TRANSPARENT_RENDER),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_TRANSPARENT_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_TRANSPARENT_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

WIREFRAME_RENDER_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.WIREFRAME_RENDER),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_WIREFRAME_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_WIREFRAME_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

RANDOM_COLOR_RENDER_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.RANDOM_COLOR_RENDER),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_RANDOM_COLOR_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_RANDOM_COLOR_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

LINE_STRIP_RENDER_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.LINE_STRIP_RENDER),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_LINE_STRIP_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_LINE_STRIP_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

SPRITE_RENDER_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.SPRITE_RENDER),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_SPRITE_DRAW_COMMANDS,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_SPRITE_DRAW_COUNT,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

DEBUG_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.DEBUG),
  scope   = .PER_CAMERA,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .CAMERA_DEPTH,
      instance = rg.PassScopedResourceTemplate{},
    },
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .CAMERA_FINAL_IMAGE,
      instance = rg.PassScopedResourceTemplate{},
    },
  },
}

POST_PROCESS_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.POST_PROCESS),
  scope   = .GLOBAL,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .POST_PROCESS_IMAGE_0,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .POST_PROCESS_IMAGE_1,
      instance = rg.FixedResourceTemplate{scope_index = 1},
    },
  },
  outputs = {
    rg.ResourceRefTemplate {
      index = .POST_PROCESS_IMAGE_0,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .POST_PROCESS_IMAGE_1,
      instance = rg.FixedResourceTemplate{scope_index = 1},
    },
  },
}

UI_PASS := rg.PassTemplate {
  id      = rg.PassTemplateId(FrameGraphPassId.UI),
  scope   = .GLOBAL,
  queue   = .GRAPHICS,
  inputs  = {
    rg.ResourceRefTemplate {
      index = .UI_VERTEX_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .UI_INDEX_BUFFER,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
    rg.ResourceRefTemplate {
      index = .POST_PROCESS_IMAGE_0,
      instance = rg.FixedResourceTemplate{scope_index = 0},
    },
  },
  outputs = {},
}
