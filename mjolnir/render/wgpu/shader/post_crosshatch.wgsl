// CrossHatchEffect: pixels darker than lum_threshold i (tonemapped luminance) get stroke
// family i: the two diagonals, then both shifted by hatch_offset_y.

// lum_thresholds as scalars: the Odin array is tightly packed, uniform arrays are not
struct Effect {
    hatch_offset_y: f32,
    lum_threshold0: f32,
    lum_threshold1: f32,
    lum_threshold2: f32,
    lum_threshold3: f32,
}

const HATCH_BRIGHTNESS: f32 = 0.65;
const STROKE_WIDTH: f32 = 1.5;
const STROKE_SPACING: f32 = 10.0;

// GLSL mod: floored, so negative coordinates repeat too
fn stroke_mask(coord: f32) -> f32 {
    let m = coord - STROKE_SPACING * floor(coord / STROKE_SPACING);
    return step(m, STROKE_WIDTH);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let rgba = textureSample(input_texture, linear_clamp, in.uv);
    let color = rgba.rgb;
    // tonemap luminance into [0, 1] so HDR scenes still hatch dark regions
    let raw_lum = dot(color, vec3f(0.2126, 0.7152, 0.0722));
    let lum = raw_lum / (raw_lum + 1.0);
    let screen_pos = in.uv * vec2f(textureDimensions(input_texture));
    let a = screen_pos.x + screen_pos.y;
    let b = screen_pos.x - screen_pos.y;
    let offset = u.effect.hatch_offset_y;
    let strokes = array(a, b, a - offset, b - offset);
    let thresholds = array(u.effect.lum_threshold0, u.effect.lum_threshold1, u.effect.lum_threshold2, u.effect.lum_threshold3);
    var hatched = 1.0;
    for (var i = 0; i < 4; i++) {
        if (lum < thresholds[i] && stroke_mask(strokes[i]) > 0.5) {
            hatched = HATCH_BRIGHTNESS;
        }
    }
    return vec4f(color * hatched, rgba.a);
}
