// Call the lightning: bolts out of the night onto a glowing grid, plain WebGL2, no dependencies.
// Click to strike, drag to look around. Mjolnir draws strikes in.
(() => {
  const canvas = document.getElementById("storm");
  if (!canvas) return;
  const figure = canvas.parentElement;
  const gl = canvas.getContext("webgl2", { antialias: false, alpha: false });
  if (!gl) { figure.hidden = true; return; }
  const floatRT = !!gl.getExtension("EXT_color_buffer_float");

  // ---------- helpers ----------
  let seed = Date.now() | 0;
  const rng = () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const gauss = () => rng() + rng() + rng() - 1.5;
  const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
  const add = (a, ...rest) => rest.reduce((s, b) => [s[0] + b[0], s[1] + b[1], s[2] + b[2]], a);
  const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const scale = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const len = (v) => Math.hypot(v[0], v[1], v[2]);
  const norm = (v) => scale(v, 1 / (len(v) || 1));
  const randDir = () => norm([gauss(), gauss(), gauss()]);

  // column-major perspective * view, from the camera basis (x = right, y = up, z = backward)
  const viewProjection = (fov, asp, eye, x, y, z) => {
    const t = 1 / Math.tan(fov / 2), n = 0.3, f = 600;
    const ex = -dot(x, eye), ey = -dot(y, eye), ez = -dot(z, eye);
    const A = (f + n) / (n - f), B = (2 * f * n) / (n - f);
    return [t / asp * x[0], t * y[0], A * z[0], -z[0],
            t / asp * x[1], t * y[1], A * z[1], -z[1],
            t / asp * x[2], t * y[2], A * z[2], -z[2],
            t / asp * ex, t * ey, A * ez + B, -ez];
  };

  // ---------- parameters (driven by the control panel) ----------
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const S = {
    rate: reduce ? 0 : 0.5, branching: 0.5, jag: 0.5, thickness: 1, restrikes: 2,
    bloom: 2, flash: reduce ? 0 : 2, orbit: !reduce,
  };

  // ---------- Mjolnir: lofted head + wrapped handle, interleaved pos / normal / color ----------
  // built head-down in hammer units (head centred on y = 0), emitted lifted onto the floor and scaled
  const HL = 1.5, HH = 0.75, HD = 0.62, HAMMER_S = 0.5, HAMMER_TIP = [0, (2 * HH + 3.53) * HAMMER_S, 0];
  const verts = [];
  const tri = (a, b, c, col, away) => {
    let n = norm(cross(sub(b, a), sub(c, a)));
    if (dot(n, sub(scale(add(a, b, c), 1 / 3), away)) < 0) { [b, c] = [c, b]; n = scale(n, -1); }
    for (const p of [a, b, c]) verts.push(p[0] * HAMMER_S, (p[1] + HH) * HAMMER_S, p[2] * HAMMER_S, ...n, ...col);
  };
  // cross-sections in the unit square, scaled per section
  const circle = (n) => Array.from({ length: n }, (_, i) => [Math.cos((i / n) * Math.PI * 2), Math.sin((i / n) * Math.PI * 2)]);
  const chamfer = (c) => [[1, -1 + c], [1, 1 - c], [1 - c, 1], [-1 + c, 1], [-1, 1 - c], [-1, -1 + c], [-1 + c, -1], [1 - c, -1]];
  // loft `shape` through sections [t, r1, r2] along x or y, capped at both ends
  const loft = (axis, secs, shape, col) => {
    const at = (t, u, v) => (axis === "x" ? [t, u, v] : [u, t, v]), sides = shape.length;
    const rings = secs.map(([t, r1, r2 = r1]) => shape.map(([u, v]) => at(t, u * r1, v * r2))), axisAt = (i) => at(secs[i][0], 0, 0);
    for (let i = 0; i + 1 < secs.length; i++) for (let j = 0; j < sides; j++) {
      const A = rings[i], B = rings[i + 1], j2 = (j + 1) % sides, mid = scale(add(axisAt(i), axisAt(i + 1)), 0.5);
      tri(A[j], B[j], B[j2], col, mid); tri(A[j], B[j2], A[j2], col, mid);
    }
    for (const [r, o] of [[0, secs.length - 1], [secs.length - 1, 0]]) {
      for (let j = 0; j < sides; j++) tri(axisAt(r), rings[r][j], rings[r][(j + 1) % sides], col, axisAt(o));
    }
  };
  const STEEL = [0.55, 0.6, 0.68], GOLD = [0.85, 0.66, 0.25], LEATHER = [0.3, 0.17, 0.09];
  const head = (secs, col) => loft("x", secs.map(([t, k]) => [t, HH * k, HD * k]), chamfer(0.2), col);
  head([[-HL, 0.8], [-HL + 0.1, 0.8], [-HL + 0.1, 1], [HL - 0.1, 1], [HL - 0.1, 0.8], [HL, 0.8]], STEEL);
  for (const x of [-HL * 0.5, HL * 0.5]) head([[x - 0.05, 1.05], [x + 0.05, 1.05]], GOLD);
  loft("y", [[HH, 0.25], [HH + 0.25, 0.17]], circle(14), GOLD);                                       // collar
  loft("y", [[HH + 0.25, 0.14], [HH + 3.25, 0.14]], circle(10), LEATHER);                             // grip
  loft("y", [[HH + 3.2, 0.2], [HH + 3.3, 0.26], [HH + 3.45, 0.26], [HH + 3.53, 0.15]], circle(14), GOLD); // pommel
  const hammerData = new Float32Array(verts);

  // ---------- gl wrapper ----------
  const compile = (vs, fs) => {
    const p = gl.createProgram();
    for (const [type, src] of [[gl.VERTEX_SHADER, vs], [gl.FRAGMENT_SHADER, fs]]) {
      const s = gl.createShader(type);
      gl.shaderSource(s, "#version 300 es\nprecision highp float;\n" + src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      gl.attachShader(p, s);
    }
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    const cache = {};
    return { p, u: (n) => (n in cache ? cache[n] : (cache[n] = gl.getUniformLocation(p, n))) };
  };
  // set uniforms by value shape: number, vec2, vec3, mat4, or a flat vec4 array
  const use = (prog, values) => {
    gl.useProgram(prog.p);
    for (const [k, v] of Object.entries(values)) {
      if (typeof v === "number") gl.uniform1f(prog.u(k), v);
      else if (v.length === 16) gl.uniformMatrix4fv(prog.u(k), false, v);
      else gl[`uniform${Math.min(v.length, 4)}fv`](prog.u(k), v);
    }
  };
  const sample = (prog, name, unit, tex) => { gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, tex); gl.uniform1i(prog.u(name), unit); };
  // `rgba` targets hold colour; the rest hold a single intensity channel
  const target = (w, h, depth, rgba) => {
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texStorage2D(gl.TEXTURE_2D, 1, rgba ? (floatRT ? gl.RGBA16F : gl.RGBA8) : (floatRT ? gl.R16F : gl.R8), w, h);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const fbo = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    if (depth) gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, depth);
    return { tex, fbo, w, h };
  };
  const bind = (t) => { gl.bindFramebuffer(gl.FRAMEBUFFER, t ? t.fbo : null); gl.viewport(0, 0, t ? t.w : canvas.width, t ? t.h : canvas.height); };
  const emptyVao = gl.createVertexArray();
  const fullscreen = () => { gl.bindVertexArray(emptyVao); gl.drawArrays(gl.TRIANGLES, 0, 3); };
  // float attributes at locations 0.. with the given component counts
  const vertexArray = (data, sizes, usage = gl.STATIC_DRAW, divisor = 0) => {
    const vao = gl.createVertexArray(), buf = gl.createBuffer(), stride = sizes.reduce((a, b) => a + b) * 4;
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, data, usage);
    let off = 0;
    sizes.forEach((n, i) => { gl.enableVertexAttribArray(i); gl.vertexAttribPointer(i, n, gl.FLOAT, false, stride, off); gl.vertexAttribDivisor(i, divisor); off += n * 4; });
    gl.bindVertexArray(null);
    return { vao, buf };
  };

  // ---------- shaders ----------
  const GLOW = "vec3(0.65, 0.7, 1.0)", HORIZON = "vec3(0.1, 0.09, 0.16)";

  const FULL_VS = `
out vec2 vUv;
void main() {
  vUv = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(vUv * 2.0 - 1.0, 0.0, 1.0);
}`;

  // plain night gradient behind the grid
  const SKY_FS = `
in vec2 vUv;
uniform vec3 uFwd, uUp;
uniform vec2 uView; // tan(fov / 2) * aspect, tan(fov / 2)
uniform float uFlash;
out vec4 o;
void main() {
  float y = dot(normalize(uFwd + (vUv.y * 2.0 - 1.0) * uView.y * uUp), vec3(0.0, 1.0, 0.0));
  o = vec4(mix(${HORIZON}, vec3(0.01, 0.012, 0.03), smoothstep(-0.05, 0.35, y)) + ${GLOW} * uFlash * 0.25, 1.0);
}`;

  const MESH_VS = `
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNrm;
layout(location = 2) in vec3 aCol;
uniform mat4 uVP;
out vec3 vPos, vNrm, vCol;
void main() {
  vPos = aPos; vNrm = aNrm; vCol = aCol;
  gl_Position = uVP * vec4(aPos, 1.0);
}`;
  // grid floor (uFloor = 1) or hammer (vCol = albedo), lit by bolt point lights
  const MESH_FS = `
in vec3 vPos, vNrm, vCol;
uniform vec3 uEye;
uniform float uFlash, uHammerGlow, uFloor, uN;
uniform vec4 uL[16];
out vec4 o;
void main() {
  vec3 n = uFloor > 0.5 ? vec3(0.0, 1.0, 0.0) : normalize(vNrm);
  float L = 0.0;
  for (int i = 0; i < 16; i++) {
    if (float(i) >= uN) break;
    vec3 d = uL[i].xyz - vPos;
    L += uL[i].w * (max(dot(n, normalize(d)), 0.0) * 0.8 + 0.2) / (1.0 + dot(d, d) / 49.0);
  }
  vec3 col;
  if (uFloor > 0.5) {
    vec2 g = vPos.xz, w = fwidth(g);
    vec2 a = abs(fract(g - 0.5) - 0.5) / w, b = abs(fract(g / 5.0 - 0.5) - 0.5) / w * 5.0;
    float lines = (1.0 - min(min(a.x, a.y), 1.0)) * 0.5 * (1.0 - smoothstep(0.1, 0.4, max(w.x, w.y)))
                + (1.0 - min(min(b.x, b.y) / 2.0, 1.0)) * 1.0 * (1.0 - smoothstep(0.5, 2.0, max(w.x, w.y)));
    col = vec3(0.015, 0.015, 0.025) * mix(0.5, 1.0, smoothstep(0.4, 2.5, length(g)));
    col = mix(col, vec3(0.45, 0.55, 0.85), clamp(lines * (0.5 + L * 2.0 + uFlash * 2.0), 0.0, 1.0));
    col += ${GLOW} * (L * 0.35 + uFlash * 0.15);
  } else {
    float key = max(dot(n, normalize(vec3(-0.4, 0.8, -0.3))), 0.0);
    float rim = pow(1.0 - abs(dot(n, normalize(uEye - vPos))), 2.0);
    col = vCol * (0.35 + key * 0.55 + ${GLOW} * (L * 0.9 + uFlash * 0.4));
    col += ${GLOW} * (rim * (0.25 + uHammerGlow * 1.5) + uHammerGlow * 0.15);
  }
  float fog = 1.0 - exp(-pow(length(vPos - uEye) * 0.019, 2.0));
  o = vec4(mix(col, ${HORIZON}, fog), 1.0);
}`;

  // bolt segments as screen-space ribbons, depth tested against the scene
  const SEG_VS = `
layout(location = 0) in vec3 aA;
layout(location = 1) in vec3 aB;
layout(location = 2) in vec2 aMeta; // world radius, intensity
uniform mat4 uVP;
uniform vec2 uRes;
uniform float uFocal;
out vec2 vP, vA, vB; out float vR, vI;
// quad corners: along the segment (0..1), side (-1..1)
const vec2 C[6] = vec2[6](vec2(0.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(0.0, -1.0), vec2(1.0, 1.0), vec2(0.0, 1.0));
void main() {
  vec2 c = C[gl_VertexID];
  vec4 ca = uVP * vec4(aA, 1.0), cb = uVP * vec4(aB, 1.0);
  if (ca.w < 0.3 || cb.w < 0.3) { gl_Position = vec4(0.0, 0.0, -2.0, 1.0); return; }
  vec2 sa = (ca.xy / ca.w * 0.5 + 0.5) * uRes, sb = (cb.xy / cb.w * 0.5 + 0.5) * uRes;
  vec2 t = length(sb - sa) > 1e-4 ? normalize(sb - sa) : vec2(0.0, 1.0), n = vec2(-t.y, t.x);
  float rc = max(aMeta.x * uFocal / mix(ca.w, cb.w, c.x), 0.7), R = rc * 5.0 + 2.0;
  vP = mix(sa, sb, c.x) + t * (c.x * 2.0 - 1.0) * R + n * c.y * R;
  vA = sa; vB = sb; vR = rc; vI = aMeta.y;
  gl_Position = vec4(vP / uRes * 2.0 - 1.0, mix(ca.z / ca.w, cb.z / cb.w, c.x), 1.0);
}`;
  const SEG_FS = `
in vec2 vP, vA, vB; in float vR, vI;
out vec4 o;
void main() {
  vec2 pa = vP - vA, ba = vB - vA;
  float k = length(pa - ba * clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0)) / vR;
  o = vec4(vI * (exp(-k * k) + 0.15 * exp(-k * 0.8)), 0.0, 0.0, 1.0);
}`;

  // bloom: each level is a 5-tap blur of the one above; the composite sums them all
  const DOWN_FS = `
in vec2 vUv; uniform sampler2D uSrc; uniform vec2 uTexel; out vec4 o;
void main() {
  vec2 t = uTexel, u = vec2(t.x, -t.y);
  o = (texture(uSrc, vUv) * 4.0 + texture(uSrc, vUv - t) + texture(uSrc, vUv + t) + texture(uSrc, vUv + u) + texture(uSrc, vUv - u)) / 8.0;
}`;

  const BLOOM_LEVELS = [1, 2, 3, 4, 5].map((i) => "uB" + i), BLOOM_UNIFORMS = BLOOM_LEVELS.join(", ");
  const COMP_FS = `
in vec2 vUv;
uniform float uBloom;
uniform sampler2D uScene, uEmis, ${BLOOM_UNIFORMS};
out vec4 o;
void main() {
  float bloom = ${BLOOM_LEVELS.map((n) => `texture(${n}, vUv).r`).join(" + ")};
  vec3 col = texture(uScene, vUv).rgb + ${GLOW} * bloom * uBloom * 0.6 + texture(uEmis, vUv).r;
  o = vec4(mix(col, 1.0 - 0.2 * exp(-(col - 0.8) / 0.2), step(0.8, col)), 1.0); // soft shoulder above 0.8
}`;

  const skyProg = compile(FULL_VS, SKY_FS);
  const meshProg = compile(MESH_VS, MESH_FS);
  const segProg = compile(SEG_VS, SEG_FS);
  const downProg = compile(FULL_VS, DOWN_FS);
  const compProg = compile(FULL_VS, COMP_FS);

  // ---------- meshes ----------
  const G = 400;
  const floor = vertexArray(new Float32Array([[-G, -G], [-G, G], [G, G], [-G, -G], [G, G], [G, -G]].flatMap(([x, z]) => [x, 0, z])), [3]);
  const hammer = vertexArray(hammerData, [3, 3, 3]);
  const MAX_SEGS = 8000, SEG_STRIDE = 8; // one instance per bolt segment: a, b, radius, intensity
  const segData = new Float32Array(MAX_SEGS * SEG_STRIDE);
  const segs = vertexArray(segData.byteLength, [3, 3, 2], gl.DYNAMIC_DRAW, 1);

  // ---------- sizing ----------
  let scene = null, emis = null, depth = null, down = [], aspect = 1;
  const syncSize = () => {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.floor(canvas.clientWidth * dpr)), h = Math.max(1, Math.floor(canvas.clientHeight * dpr));
    aspect = w / h;
    if (scene && canvas.width === w && canvas.height === h) return;
    canvas.width = w; canvas.height = h;
    if (scene) {
      for (const t of [scene, emis, ...down]) { gl.deleteTexture(t.tex); gl.deleteFramebuffer(t.fbo); }
      gl.deleteRenderbuffer(depth);
    }
    depth = gl.createRenderbuffer();
    gl.bindRenderbuffer(gl.RENDERBUFFER, depth);
    gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, w, h);
    scene = target(w, h, depth, true);
    emis = target(w, h, depth);
    down = [1, 2, 3, 4, 5].map((i) => target(Math.max(1, w >> i), Math.max(1, h >> i)));
  };

  // ---------- camera ----------
  const FOV = (50 * Math.PI) / 180, TAN = Math.tan(FOV / 2), LOOK = [0, 1.8, 0];
  const cam = { yaw: 0.9, pitch: 0.12, dist: 9 };
  let eye, fwd, right, camUp, viewProj;
  const updateCamera = () => {
    const cp = Math.cos(cam.pitch);
    eye = add(LOOK, [cam.dist * cp * Math.sin(cam.yaw), cam.dist * Math.sin(cam.pitch), cam.dist * cp * Math.cos(cam.yaw)]);
    eye[1] = Math.max(eye[1], 0.4);
    fwd = norm(sub(LOOK, eye)); right = norm(cross(fwd, [0, 1, 0])); camUp = cross(right, fwd);
    viewProj = viewProjection(FOV, aspect, eye, right, camUp, scale(fwd, -1));
  };
  // where a screen point's ray meets the floor (or a far floor point under it), and whether it hits the hammer
  const pick = (u, v) => {
    const dir = norm(add(fwd, scale(right, (u * 2 - 1) * TAN * aspect), scale(camUp, (v * 2 - 1) * TAN)));
    const t = dir[1] < -1e-3 ? Math.min(-eye[1] / dir[1], 60) : 60;
    const hit = add(eye, scale(dir, t));
    hit[1] = 0;
    // or passes through a vertical cylinder (radius 1.2) around the hammer below its tip
    let toHammer = Math.hypot(hit[0], hit[2]) < 1.6;
    const a = dir[0] ** 2 + dir[2] ** 2, b = eye[0] * dir[0] + eye[2] * dir[2], disc = b * b - a * (eye[0] ** 2 + eye[2] ** 2 - 1.44);
    if (!toHammer && a > 1e-6 && disc >= 0) {
      const r = Math.sqrt(disc), s0 = Math.max((-b - r) / a, 0), s1 = Math.min((-b + r) / a, t);
      toHammer = s0 <= s1 && Math.min(eye[1] + dir[1] * s0, eye[1] + dir[1] * s1) < HAMMER_TIP[1] + 0.8;
    }
    return { hit, toHammer };
  };

  // ---------- bolts ----------
  // a bolt's segments are {a, b, t, w, lvl}: endpoints, time the leader reaches it, radius, branch depth
  const SKY_Y = 18;
  const bolts = [];
  let time = 0;

  // random walk from a toward b; the last point is exactly b
  const walk = (a, b, step, jag) => {
    const pts = [a];
    let p = a, drift = [0, 0, 0];
    for (let n = 0; n < 600; n++) {
      const d = sub(b, p), rem = len(d);
      if (rem < step * 1.2) break;
      drift = scale(add(drift, scale(randDir(), 0.25)), 0.88);
      const wander = scale(add(drift, scale(randDir(), jag * 1.4)), Math.min(1, rem / 3));
      p = add(p, scale(norm(add(scale(d, 1 / rem), wander)), step * (0.6 + rng() * 0.8)));
      pts.push(p);
    }
    pts.push(b);
    return pts;
  };

  const branch = (out, p, dir, t0, dt, w, lvl, steps, prob) => {
    for (let j = 0; j < steps; j++) {
      const d = norm(add(dir, scale(randDir(), S.jag * 1.2)));
      const q = add(p, scale(d, 0.3 * (0.6 + rng() * 0.8)));
      const tw = w * (1 - (j / steps) * 0.6);
      out.push({ a: p, b: q, t: t0 + j * dt, w: tw, lvl });
      if (lvl < 3 && rng() < prob * 0.5) {
        branch(out, q, norm(add(d, scale(randDir(), 0.9))), t0 + j * dt, dt, tw * 0.55, lvl + 1, Math.floor((steps - j) * (0.3 + rng() * 0.5)), prob * 0.5);
      }
      dir = norm(add(scale(dir, 0.92), [0, -0.08, 0])); // sag toward the ground
      p = q;
    }
  };

  const grow = (pts, power, leaderDur, prob) => {
    const out = [], dt = leaderDur / (pts.length - 1), w = 0.035 * S.thickness * (0.7 + power * 0.3);
    for (let i = 0; i + 1 < pts.length; i++) {
      out.push({ a: pts[i], b: pts[i + 1], t: i * dt, w, lvl: 0 });
      if (i > 1 && i < pts.length - 4 && rng() < prob) {
        const steps = Math.floor((4 + rng() * (8 + 24 * S.branching)) * (1 - (i / pts.length) * 0.6));
        branch(out, pts[i], norm(add(norm(sub(pts[i + 1], pts[i])), scale(randDir(), 0.9))), i * dt, dt * 1.1, w * 0.5, 1, steps, prob);
      }
    }
    return out;
  };

  // sky to floor strike: stepped leader, then a return stroke and re-strikes along the same channel
  const strike = (to, power, toHammer) => {
    const end = toHammer ? HAMMER_TIP : to;
    const pts = walk([end[0] + gauss() * 6, SKY_Y - rng() * 1.5, end[2] + gauss() * 6], end, 0.35, S.jag);
    const leaderDur = 0.12 + rng() * 0.1, strokes = [{ t: leaderDur, amp: 1 }];
    for (let i = 0; i < S.restrikes; i++) strokes.push({ t: strokes[i].t + 0.05 + rng() * 0.09, amp: 0.75 - i * 0.12 });
    const parts = grow(pts, power, leaderDur, S.branching * 0.2 * (0.6 + power * 0.4));
    bolts.push({ born: time, segs: parts, pts, leaderDur, strokes, power, toHammer, end: strokes.at(-1).t + 1.2 });
  };

  const envelope = (b, a, tau) => b.strokes.reduce((e, s) => e + (a >= s.t ? s.amp * Math.exp(-(a - s.t) / tau) : 0), 0)
    + (a >= b.leaderDur ? 0.12 * Math.exp(-(a - b.leaderDur) / 0.4) : 0);
  const intensity = (b, s, a) => {
    if (a < s.t) return 0;
    const fresh = Math.exp(-(a - s.t) / 0.015), k = [1, 0.55, 0.4, 0.3][s.lvl];
    if (a < b.leaderDur) return (0.22 + fresh * 0.7) * k;
    if (s.lvl === 0) return envelope(b, a, 0.045) * 1.6 * b.power;
    return k * (0.8 * Math.exp(-(a - b.leaderDur) / 0.035) + 0.15 * Math.max(0, envelope(b, a, 0.03) - 1));
  };

  // ---------- input: tap to strike, drag to look around ----------
  let pointer = null;
  canvas.addEventListener("pointerdown", (e) => {
    try { canvas.setPointerCapture(e.pointerId); } catch {}
    const r = canvas.getBoundingClientRect();
    pointer = { id: e.pointerId, x: e.clientX, y: e.clientY, drag: false, ...pick((e.clientX - r.left) / r.width, 1 - (e.clientY - r.top) / r.height) };
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!pointer || e.pointerId !== pointer.id) return;
    const dx = e.clientX - pointer.x, dy = e.clientY - pointer.y;
    if (!pointer.drag && Math.hypot(dx, dy) < 6) return;
    pointer.drag = true;
    cam.yaw -= dx * 0.005;
    cam.pitch = clamp(cam.pitch + dy * 0.004, -0.05, 0.7);
    pointer.x = e.clientX; pointer.y = e.clientY;
  });
  const release = (e) => {
    if (!pointer || e.pointerId !== pointer.id) return;
    if (e.type === "pointerup" && !pointer.drag) strike(pointer.hit, 1 + rng() * 0.5, pointer.toHammer);
    pointer = null;
  };
  canvas.addEventListener("pointerup", release);
  canvas.addEventListener("pointercancel", release);

  // ---------- frame ----------
  let flash = 0, lastFlash = -1, hammerGlow = 0, nextAuto = 0.8;
  const lights = new Float32Array(16 * 4);
  const update = (dt) => {
    time += dt;
    if (S.orbit && !pointer) cam.yaw += dt * 0.04;
    updateCamera();
    if (S.rate > 0 && time >= nextAuto) {
      const a = rng() * Math.PI * 2, d = 4 + rng() * 40;
      strike([Math.sin(a) * d, 0, Math.cos(a) * d], 0.7 + rng() * 0.7, rng() < 0.25);
      nextAuto = time + (0.4 + rng() * 1.6) / Math.max(S.rate, 0.05);
    }

    let n = 0;
    const light = (p, i) => { if (n < 16 && i > 0.01) lights.set([...p, i], 4 * n++); };
    for (let i = bolts.length - 1; i >= 0; i--) {
      const b = bolts[i], a = time - b.born, pts = b.pts, mid = pts[pts.length >> 1], last = pts.at(-1);
      if (a > b.end) { bolts.splice(i, 1); continue; }
      if (a < b.leaderDur) { light(pts[Math.floor((a / b.leaderDur) * (pts.length - 1))], 0.2); continue; }
      if (!b.struck) {
        b.struck = true;
        const dist = len(sub(last, eye));
        // full-view flashes are rate limited and only follow the first stroke
        if (time - lastFlash > 0.45) { flash = Math.max(flash, b.power * clamp(1.4 - dist / 60, 0.3, 1)); lastFlash = time; }
        if (b.toHammer) hammerGlow = 1;
      }
      const e = envelope(b, a, 0.06) * b.power;
      light(last, e * 1.2); light(mid, e * 0.8); light(pts[0], e * 0.8);
    }
    hammerGlow *= Math.exp(-dt / 1.5);
    if (hammerGlow > 0.02) light(add(HAMMER_TIP, [0, -1, 0]), hammerGlow * 0.4);
    flash *= Math.exp(-dt / 0.25);
    return n;
  };

  const draw = (nLights) => {
    const flashU = Math.min(flash, 1) * S.flash * 0.35;

    // 1. scene: sky, grid floor, hammer
    bind(scene);
    gl.clear(gl.DEPTH_BUFFER_BIT);
    use(skyProg, { uFwd: fwd, uUp: camUp, uView: [TAN * aspect, TAN], uFlash: flashU });
    fullscreen();
    gl.enable(gl.DEPTH_TEST);
    use(meshProg, { uVP: viewProj, uEye: eye, uFlash: flashU, uHammerGlow: hammerGlow, uL: lights, uN: nLights, uFloor: 1 });
    gl.bindVertexArray(floor.vao);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    gl.uniform1f(meshProg.u("uFloor"), 0);
    gl.bindVertexArray(hammer.vao);
    gl.drawArrays(gl.TRIANGLES, 0, hammerData.length / 9);

    // 2. bolts into the emissive target, depth tested against the scene
    let v = 0;
    for (const b of bolts) for (const s of b.segs) {
      const I = intensity(b, s, time - b.born);
      if (I < 0.003 || v >= MAX_SEGS) continue;
      segData.set([...s.a, ...s.b, s.w, I], SEG_STRIDE * v++);
    }
    bind(emis);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (v) {
      gl.depthMask(false);
      gl.enable(gl.BLEND);
      gl.blendEquation(gl.MAX);
      use(segProg, { uVP: viewProj, uRes: [canvas.width, canvas.height], uFocal: canvas.height * 0.5 / TAN });
      gl.bindVertexArray(segs.vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, segs.buf);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, segData, 0, v * SEG_STRIDE);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, v);
      gl.disable(gl.BLEND);
      gl.depthMask(true);
    }
    gl.disable(gl.DEPTH_TEST);

    // 3. bloom
    let src = emis;
    for (const d of down) {
      bind(d);
      use(downProg, { uTexel: [1 / src.w, 1 / src.h] });
      sample(downProg, "uSrc", 0, src.tex);
      fullscreen();
      src = d;
    }

    // 4. composite
    bind(null);
    use(compProg, { uBloom: S.bloom });
    sample(compProg, "uScene", 0, scene.tex);
    sample(compProg, "uEmis", 1, emis.tex);
    down.forEach((d, i) => sample(compProg, BLOOM_LEVELS[i], i + 2, d.tex));
    fullscreen();
  };

  let visible = true, running = false, last = 0;
  const frame = (now) => {
    if (!visible || document.hidden) { running = false; return; }
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
    syncSize();
    draw(update(dt));
    requestAnimationFrame(frame);
  };
  const start = () => {
    if (running || !visible || document.hidden) return;
    running = true;
    requestAnimationFrame((now) => { last = now; frame(now); });
  };

  // ---------- control panel (markup lives in index.html) ----------
  const toggle = figure.querySelector("button"), panel = figure.querySelector("aside");
  toggle.onclick = () => {
    panel.hidden = !panel.hidden;
    toggle.textContent = panel.hidden ? "«" : "»";
    toggle.setAttribute("aria-expanded", String(!panel.hidden));
  };
  for (const input of panel.querySelectorAll("input[data-key]")) {
    const key = input.dataset.key, box = input.type === "checkbox";
    if (box) input.checked = S[key]; else input.value = S[key];
    input.oninput = () => {
      S[key] = box ? input.checked : +input.value;
      if (key === "rate") nextAuto = time + 0.3;
    };
  }
  if (reduce) panel.querySelector("[data-key=flash]").parentElement.hidden = true;
  panel.hidden = true;

  new IntersectionObserver((e) => { visible = e[0].isIntersecting; start(); }).observe(canvas);
  document.addEventListener("visibilitychange", start);
  start();
})();
