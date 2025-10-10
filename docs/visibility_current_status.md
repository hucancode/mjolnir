# 2-Pass Occlusion Culling - Current Status

## Summary

## Current Behavior

### Test Scene Stats
- **Total objects:** 57,138
- **Frustum culled:** 582 objects visible
- **Expected with occlusion:** <50 objects visible
- **Actual result:** 582 objects (same as frustum-only)

### Frame-by-Frame Results
```
Frame 0:  Early=0,   Late=0    (bootstrap - expected)
Frame 6:  Early=0,   Late=582  (warming up)
Frame 11: Early=582, Late=582  (converged)
Frame 16: Early=582, Late=582  (stable)
Frame 21+: Early=582, Late=582  (stable)
```

## Remaining Issue: Occlusion Not Reducing Count

**Symptom:** Late pass generates 582 draws (same as frustum-only), meaning occlusion test passes everything.

**Root Cause:** Depth pyramid is likely all 1.0 (far plane), suggesting early depth render isn't writing depth properly OR there's a pipeline/synchronization issue.

### Possible Causes

1. **Early depth shader not writing depth**
   - Check `mjolnir/shader/depth_prepass/shader.vert` outputs correct `gl_Position`
   - Verify fragment shader isn't discarding

2. **Depth pyramid generation issue**
   - Check `_generate_depth_pyramid()` is copying early_depth correctly
   - Verify mip generation shader samples correct texture/mip
   - Check image layout transitions

3. **Late pass sampling wrong texture**
   - Verify `late_cull.comp` binding 4 points to correct depth pyramid
   - Check sampler uses NEAREST and CLAMP

4. **Synchronization/barrier issue**
   - Early depth render → pyramid generation barrier
   - Pyramid generation → late pass barrier
   - Verify all pipeline stages sync correctly

### Debug Strategy

**Option A: Verify early depth writes**
Add debug output in early depth vertex shader to confirm it's being called:
```glsl
// In depth_prepass/shader.vert
// Add atomic counter increment to confirm execution
```

**Option B: Check pyramid mip 0**
Read back pyramid mip 0 after generation and verify it's not all 1.0:
```odin
// After _generate_depth_pyramid()
// vkCmdCopyImageToBuffer and check values
```

**Option C: Test with simpler occlusion**
Temporarily modify late_cull.comp to always occlude if depth < 0.5:
```glsl
if (occluder_depth < 0.5) {  // Simple test
    visibility[node_id] = 0u;
    return;
}
```

## What Needs Work ⚠️

1. ⚠️ Occlusion culling effectiveness (582 → should be <50)
2. ⚠️ Depth pyramid generation or sampling
3. ⚠️ Early depth render verification


### Possible Causes

1. **Depth texture sampling issue**
   - May need to check if the depth values are actually being read correctly

2. **Early depth rendering not writing values**
   - The early depth pass may not be writing valid depth values
   - Could add debug verification by reading back the depth texture

3. **Depth pyramid generation not working**
   - The compute shader may not be correctly downsampling the depth
   - Could add debug output in the shader to verify execution

4. **Synchronization issue**
   - Memory barriers may not be ensuring visibility
   - Could be a cache coherency issue with depth textures

## Next Steps

1. Add debug readback of early depth texture to verify it contains valid values (not all 1.0)
2. Add debug readback of pyramid mip 0 to verify downsampling works
3. Consider using RenderDoc to capture a frame and inspect the depth pyramid
4. Verify the depth comparison logic in late_cull.comp is correct for the depth range being used
5. Check if depth bias (currently 0.01) needs adjustment

1. Verify early depth shader is writing depth values
2. Check depth pyramid generation is creating valid mip chain
3. Confirm late pass is reading correct depth pyramid texture
4. Add GPU debug markers around each pass for RenderDoc capture
5. Consider reading back depth pyramid mip 0 to CPU for inspection
