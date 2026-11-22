#+build !js
#+private file
package render

import "../containers"
import "core:log"
import "core:testing"

SPRITE_ONLY :: CameraFilter{types = {int(MaterialType.SPRITE)}}

// Cameras and post shaders on the CPU side, no device.
effect_renderer :: proc() -> ^Renderer {
  r := new(Renderer)
  containers.slots_init(&r.slots[.CAMERAS], 8)
  containers.slots_init(&r.slots[.SHADERS], 8)
  r.camera_targets = make([]CameraTargets, 8)
  r.cameras = make([]Camera, 8)
  r.shaders = make([dynamic]Shader, 8)
  return r
}

effect_renderer_destroy :: proc(r: ^Renderer) {
  for &s in r.slots do containers.slots_destroy(&s)
  delete(r.camera_targets)
  delete(r.cameras)
  delete(r.shaders)
  graph_destroy(&r.frame_graph)
  free(r)
}

add_camera :: proc(r: ^Renderer, filter: CameraFilter) -> CameraHandle {
  c, _ := containers.slots_alloc(&r.slots[.CAMERAS])
  r.camera_targets[c] = {extent = {64, 64}, filter = filter}
  camera_effects_default(r, c)
  return CameraHandle(c)
}

@(test)
test_sprite_camera_refuses_gbuffer_effects :: proc(t: ^testing.T) {
  // the refusals log errors
  context.logger = log.nil_logger()
  r := effect_renderer()
  defer effect_renderer_destroy(r)
  cam := add_camera(r, SPRITE_ONLY)
  _, has_ao := camera_effect_get(r, cam, AmbientOcclusion)
  testing.expect(t, !has_ao, "a camera without the G-buffer starts without ambient occlusion")
  testing.expect(t, !camera_effect(r, cam, DEFAULT_AMBIENT_OCCLUSION))
  testing.expect(t, !camera_effect(r, cam, OutlineEffect{thickness = 1}))
  _, has_outline := camera_effect_get(r, cam, OutlineEffect)
  testing.expect(t, !has_outline, "a refused effect changes nothing")
  testing.expect(t, camera_effect(r, cam, FogEffect{start = 1, end = 10}))
  testing.expect(t, camera_effect(r, cam, BloomEffect{threshold = 1, intensity = 1}))
  fog, has_fog := camera_effect_get(r, cam, FogEffect)
  testing.expect(t, has_fog && fog.end == 10)
  testing.expect(t, camera_effect(r, cam, FogEffect{}, enabled = false))
  _, has_fog = camera_effect_get(r, cam, FogEffect)
  testing.expect(t, !has_fog)
}

@(test)
test_deferred_camera_takes_every_effect :: proc(t: ^testing.T) {
  r := effect_renderer()
  defer effect_renderer_destroy(r)
  cam := add_camera(r, FILTER_ALL)
  _, has_ao := camera_effect_get(r, cam, AmbientOcclusion)
  testing.expect(t, has_ao, "a camera with the G-buffer starts with ambient occlusion")
  testing.expect(t, camera_effect(r, cam, OutlineEffect{thickness = 1}))
  testing.expect(t, !camera_effect(r, CameraHandle(7), FogEffect{}), "a stale handle")
}

@(test)
test_normals_post_shader_needs_gbuffer :: proc(t: ^testing.T) {
  // the refusals log errors
  context.logger = log.nil_logger()
  r := effect_renderer()
  defer effect_renderer_destroy(r)
  sprite, deferred := add_camera(r, SPRITE_ONLY), add_camera(r, FILTER_ALL)
  plain, _ := containers.slots_alloc(&r.slots[.SHADERS])
  normals, _ := containers.slots_alloc(&r.slots[.SHADERS])
  r.shaders[plain] = {kind = .POST}
  r.shaders[normals] = {kind = .POST, normals = true}
  testing.expect(t, camera_post_shaders(r, sprite, {shader = ShaderHandle(plain)}))
  testing.expect(t, !camera_post_shaders(r, sprite, {shader = ShaderHandle(normals)}))
  testing.expect_value(t, r.camera_targets[sprite].shaders[0].shader, ShaderHandle(plain))
  testing.expect(t, camera_post_shaders(r, deferred, {shader = ShaderHandle(normals)}))
  testing.expect(t, !camera_post_shaders(r, deferred, {shader = ShaderHandle(99)}), "not a post shader")
}

@(test)
test_sprite_camera_declares_no_gbuffer :: proc(t: ^testing.T) {
  r := effect_renderer()
  defer effect_renderer_destroy(r)
  sprite := add_camera(r, SPRITE_ONLY)
  camera_effect(r, sprite, BloomEffect{threshold = 1, intensity = 1})
  camera_declare(r, u32(sprite), false)
  kinds: bit_set[PassKind]
  for p in r.frame_graph.passes do kinds += {p.kind}
  testing.expect(t, kinds & {.GBUFFER, .AMBIENT_OCCLUSION, .LIGHTING} == {})
  testing.expect(t, .FORWARD in kinds)
  testing.expect(t, .EFFECT in kinds)
  // the forward pass draws into a transient lit image that bloom carries into the camera's own
  graph_compile(&r.frame_graph)
  testing.expect(t, len(r.frame_graph.physical) > 1)
}
