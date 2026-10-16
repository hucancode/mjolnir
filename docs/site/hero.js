// Procedural Mjolnir hammer floating over a grid, plain WebGL, no dependencies.
(() => {
  const canvas = document.getElementById("hero-canvas");
  if (!canvas) return;
  const gl = canvas.getContext("webgl", { antialias: true, alpha: true, premultipliedAlpha: true });
  if (!gl) { canvas.hidden = true; return; }

  // ---------- vector helpers ----------
  const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const norm = (v) => { const l = Math.hypot(...v) || 1; return [v[0] / l, v[1] / l, v[2] / l]; };
  const shade = (c, k) => c.map((x) => x * k);

  // ---------- geometry: interleaved pos / normal / color, flat shaded ----------
  const metal = [], matte = [], lines = [];
  // `out` = point the triangle should face away from (undefined: trust winding)
  const tri = (dst, a, b, c, col, away) => {
    let n = norm(cross(sub(b, a), sub(c, a)));
    if (away) {
      const m = [(a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3];
      if (dot(n, sub(m, away)) < 0) { [b, c] = [c, b]; n = [-n[0], -n[1], -n[2]]; }
    }
    for (const p of [a, b, c]) dst.push(p[0], p[1], p[2], n[0], n[1], n[2], col[0], col[1], col[2]);
  };

  // cross-sections: points in the (u,v) plane
  const circle = (n) => (rx, ry) => Array.from({ length: n }, (_, i) => {
    const a = (i / n) * Math.PI * 2; return [Math.cos(a) * rx, Math.sin(a) * ry];
  });
  // rectangle with chamfered corners (octagon)
  const chamfer = (c) => (rx, ry) => {
    c = Math.min(c, rx * 0.9, ry * 0.9);
    return [[rx, -ry + c], [rx, ry - c], [rx - c, ry], [-rx + c, ry],
            [-rx, ry - c], [-rx, -ry + c], [-rx + c, -ry], [rx - c, -ry]];
  };
  const place = { x: (t, u, v) => [t, u, v], y: (t, u, v) => [u, t, v] };

  // loft along an axis through sections {t, rx, ry}, capped at both ends
  const loft = (dst, axis, secs, ring, col, shadeFn) => {
    const P = place[axis];
    const rings = secs.map((s) => ring(s.rx, s.ry).map(([u, v]) => P(s.t, u, v)));
    const centers = secs.map((s) => P(s.t, 0, 0));
    for (let i = 0; i + 1 < secs.length; i++) {
      const A = rings[i], B = rings[i + 1], n = A.length;
      const k = shadeFn ? shadeFn(i) : 1;
      for (let j = 0; j < n; j++) {
        const j2 = (j + 1) % n, mid = P((secs[i].t + secs[i + 1].t) / 2, 0, 0);
        tri(dst, A[j], B[j], B[j2], shade(col, k), mid);
        tri(dst, A[j], B[j2], A[j2], shade(col, k), mid);
      }
    }
    const cap = (ringPts, c, away) => {
      for (let j = 0; j < ringPts.length; j++) tri(dst, c, ringPts[j], ringPts[(j + 1) % ringPts.length], shade(col, 0.9), away);
    };
    const last = secs.length - 1;
    cap(rings[0], centers[0], centers[last]);
    cap(rings[last], centers[last], centers[0]);
  };

  // torus in the XY plane
  const torus = (dst, cx, cy, R, r, col, seg = 28, sides = 8) => {
    const pt = (i, j) => {
      const a = (i / seg) * Math.PI * 2, b = (j / sides) * Math.PI * 2;
      const d = R + Math.cos(b) * r;
      return [cx + Math.cos(a) * d, cy + Math.sin(a) * d, Math.sin(b) * r];
    };
    for (let i = 0; i < seg; i++) for (let j = 0; j < sides; j++) {
      const a = pt(i, j), b = pt(i + 1, j), c = pt(i + 1, j + 1), d = pt(i, j + 1);
      const away = [cx + Math.cos(((i + 0.5) / seg) * Math.PI * 2) * R, cy + Math.sin(((i + 0.5) / seg) * Math.PI * 2) * R, 0];
      tri(dst, a, b, c, col, away); tri(dst, a, c, d, col, away);
    }
  };

  // axis-aligned box
  const box = (dst, x0, y0, z0, x1, y1, z1, col) => {
    const c = [(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2];
    const v = (x, y, z) => [x, y, z];
    const f = [[v(x0, y0, z0), v(x1, y0, z0), v(x1, y1, z0), v(x0, y1, z0)], [v(x0, y0, z1), v(x1, y0, z1), v(x1, y1, z1), v(x0, y1, z1)],
               [v(x0, y0, z0), v(x0, y0, z1), v(x0, y1, z1), v(x0, y1, z0)], [v(x1, y0, z0), v(x1, y0, z1), v(x1, y1, z1), v(x1, y1, z0)],
               [v(x0, y0, z0), v(x1, y0, z0), v(x1, y0, z1), v(x0, y0, z1)], [v(x0, y1, z0), v(x1, y1, z0), v(x1, y1, z1), v(x0, y1, z1)]];
    for (const q of f) { tri(dst, q[0], q[1], q[2], col, c); tri(dst, q[0], q[2], q[3], col, c); }
  };

  // ---------- parameters (driven by the control panel) ----------
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const S = {
    slant: 45, spin: false, finish: "steel", headLength: 1.5, handleLength: 3, loop: true,
    orbit: !reduce, orbitSpeed: 0.12, distance: 14, height: 4.5,
    sunAzimuth: 35, sunElevation: 50, theme: "auto",
    grid: true, gridSpacing: 1, gridOpacity: 0.8, gridFade: 40, shadow: true,
  };

  // ---------- Mjolnir, built along +Y: head at the origin, handle hanging down ----------
  const FINISH = { steel: [0.55, 0.6, 0.68], bronze: [0.72, 0.46, 0.28], obsidian: [0.15, 0.16, 0.22] };
  const GOLD = [0.85, 0.66, 0.25], LEATHER = [0.30, 0.17, 0.09], STRAP = [0.5, 0.33, 0.18];
  const buildHammer = () => {
  metal.length = 0; matte.length = 0;
  const STEEL = FINISH[S.finish];
  const HL = S.headLength, HH = 0.75, HD = 0.62; // head half-length (x), half-height (y), half-depth (z)

  // head: a chamfered block whose striking faces have a raised rim around a recessed centre
  const headSecs = [
    { t: -HL, rx: HH * 0.8, ry: HD * 0.8 },       // recessed face
    { t: -HL + 0.09, rx: HH * 0.8, ry: HD * 0.8 },
    { t: -HL + 0.09, rx: HH * 0.96, ry: HD * 0.96 }, // rim
    { t: -HL + 0.2, rx: HH, ry: HD },
    { t: -HL * 0.55, rx: HH, ry: HD },
    { t: -HL * 0.55, rx: HH * 1.04, ry: HD * 1.06 }, // gold band
    { t: -HL * 0.45, rx: HH * 1.04, ry: HD * 1.06 },
    { t: -HL * 0.45, rx: HH, ry: HD },
    { t: HL * 0.45, rx: HH, ry: HD },
    { t: HL * 0.45, rx: HH * 1.04, ry: HD * 1.06 },
    { t: HL * 0.55, rx: HH * 1.04, ry: HD * 1.06 },
    { t: HL * 0.55, rx: HH, ry: HD },
    { t: HL - 0.2, rx: HH, ry: HD },
    { t: HL - 0.09, rx: HH * 0.96, ry: HD * 0.96 },
    { t: HL - 0.09, rx: HH * 0.8, ry: HD * 0.8 },
    { t: HL, rx: HH * 0.8, ry: HD * 0.8 },
  ];
  // the head is lofted along x with cross-section (y,z): swap via place.x → [t,u,v]
  loft(metal, "x", headSecs.map((s) => ({ t: s.t, rx: s.rx, ry: s.ry })), chamfer(0.2), STEEL,
       (i) => ([1, 4, 5, 6, 9, 10].includes(i) ? 1.3 : 1));
  // gold bands are the sections 5-6 and 9-10: recolour by overlaying slim gold rings
  for (const x of [-HL * 0.5, HL * 0.5]) {
    loft(metal, "x", [{ t: x - 0.05, rx: HH * 1.045, ry: HD * 1.07 }, { t: x + 0.05, rx: HH * 1.045, ry: HD * 1.07 }], chamfer(0.2), GOLD);
  }
  // engraved-looking knotwork: small gold studs along the top and bottom of the head
  for (let i = -Math.round(HL * 2.2); i <= Math.round(HL * 2.2); i++) for (const s of [-1, 1]) {
    const x = i * 0.28, y = s * (HH + 0.005);
    box(metal, x - 0.06, Math.min(y, y + s * 0.03), -0.2, x + 0.06, Math.max(y, y + s * 0.03), 0.2, shade(GOLD, 0.85));
  }

  // collar where the handle meets the head
  loft(metal, "y", [{ t: -HH - 0.02, rx: 0.25, ry: 0.25 }, { t: -HH - 0.22, rx: 0.22, ry: 0.22 },
                    { t: -HH - 0.25, rx: 0.17, ry: 0.17 }], circle(14), GOLD);

  // handle: wrapped leather, built as many thin sections
  const HANDLE_TOP = -HH - 0.25, HANDLE_END = -(HH + 0.25 + S.handleLength);
  const hs = [];
  for (let y = HANDLE_TOP; y >= HANDLE_END; y -= 0.07) {
    const wrap = y < -1.9 && y > HANDLE_END + 0.9 ? (Math.floor((HANDLE_TOP - y) / 0.07) % 2 ? 0.012 : -0.006) : 0;
    hs.push({ t: y, rx: 0.14 + wrap, ry: 0.14 + wrap });
  }
  hs.reverse();
  loft(matte, "y", hs, circle(10), LEATHER, (i) => (i % 2 ? 1.08 : 0.92));

  // the belt: a strap wound around the end of the handle with a buckle, then a loop
  const BELT_Y = HANDLE_END + 0.55;
  loft(matte, "y", [{ t: BELT_Y - 0.28, rx: 0.19, ry: 0.19 }, { t: BELT_Y + 0.28, rx: 0.19, ry: 0.19 }], circle(14), STRAP);
  for (const dy of [-0.3, 0.3]) loft(metal, "y", [{ t: BELT_Y + dy - 0.025, rx: 0.2, ry: 0.2 }, { t: BELT_Y + dy + 0.025, rx: 0.2, ry: 0.2 }], circle(14), GOLD);
  box(metal, 0.17, BELT_Y - 0.14, -0.1, 0.25, BELT_Y + 0.14, 0.1, GOLD); // buckle
  box(metal, 0.2, BELT_Y - 0.07, -0.06, 0.28, BELT_Y + 0.07, 0.06, shade(GOLD, 0.7)); // tongue
  // pommel cap
  loft(metal, "y", [{ t: HANDLE_END + 0.02, rx: 0.2, ry: 0.2 }, { t: HANDLE_END - 0.05, rx: 0.26, ry: 0.26 },
                    { t: HANDLE_END - 0.2, rx: 0.26, ry: 0.26 }, { t: HANDLE_END - 0.28, rx: 0.15, ry: 0.15 }], circle(14), GOLD);
  // hanging wrist loop
  if (S.loop) torus(matte, 0, HANDLE_END - 0.28 - 0.38, 0.38, 0.05, STRAP);
  };



  // ground: grid lines (pos, normal, intensity)
  const EXT = 100;
  for (let i = -EXT; i <= EXT; i++) {
    const k = i % 5 === 0 ? 1.0 : 0.45;
    lines.push(i, 0, -EXT, 0, 1, 0, k, k, k, i, 0, EXT, 0, 1, 0, k, k, k,
               -EXT, 0, i, 0, 1, 0, k, k, k, EXT, 0, i, 0, 1, 0, k, k, k);
  }
  const lineCount = lines.length / 9;
  // soft contact shadow under the hammer
  const shadowSrc = [];
  tri(shadowSrc, [-14, 0.01, -14], [-14, 0.01, 14], [14, 0.01, 14], [0, 0, 0]);
  tri(shadowSrc, [-14, 0.01, -14], [14, 0.01, 14], [14, 0.01, -14], [0, 0, 0]);

  const lineStart = 0, shadowStart = lineCount, metalStart = lineCount + 6;
  let metalCount = 0, matteCount = 0, matteStart = 0, all = null;

  // ---------- shaders ----------
  const compile = (type, src) => {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const program = (vs, fs) => {
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl.VERTEX_SHADER, vs)); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  };
  let sceneP;
  try {
    sceneP = program(`
      attribute vec3 aPos, aNrm, aCol;
      uniform mat4 uVP, uModel;
      varying vec3 vPos, vNrm, vCol;
      void main() {
        vec4 p = uModel * vec4(aPos, 1.0);
        vPos = p.xyz; vNrm = mat3(uModel) * aNrm; vCol = aCol;
        gl_Position = uVP * p;
      }`, `
      precision mediump float;
      varying vec3 vPos, vNrm, vCol;
      uniform vec3 uSun, uEye, uSkyAmb, uGround, uGrid;
      uniform float uMode, uGridAlpha; uniform vec3 uShadow; uniform vec2 uFade;
      void main() {
        vec3 col; float a = 1.0;
        vec3 v = normalize(uEye - vPos);
        if (uMode > 2.5) {            // contact shadow
          vec2 p = vPos.xz; float c = cos(uShadow.z), s = sin(uShadow.z);
          vec2 q = vec2(p.x * c - p.y * s, p.x * s + p.y * c) / uShadow.xy;
          col = vec3(0.0); a = 0.45 * smoothstep(1.0, 0.0, length(q));
        } else if (uMode > 1.5) {     // grid
          col = uGrid;
          a = vCol.r * uGridAlpha * (1.0 - smoothstep(uFade.x, uFade.y, length(vPos.xz)));
        } else {
          vec3 n = normalize(vNrm);
          if (dot(n, v) < 0.0) n = -n;
          float d = max(dot(n, uSun), 0.0);
          vec3 amb = mix(uGround, uSkyAmb, n.y * 0.5 + 0.5);
          if (uMode > 0.5) {          // metal: fake environment + specular
            vec3 r = reflect(-v, n);
            vec3 env = mix(uGround, uSkyAmb * 1.3, smoothstep(-0.4, 0.6, r.y));
            vec3 h = normalize(uSun + v);
            float sp = pow(max(dot(n, h), 0.0), 48.0);
            col = vCol * (0.35 * amb + d * 0.55) + env * vCol * 0.55 + sp * vec3(1.0, 0.95, 0.85);
          } else {
            col = vCol * (amb * 0.9 + d * vec3(1.0, 0.92, 0.8) * 0.8);
          }
        }
        gl_FragColor = vec4(col, a);
      }`);
  } catch (e) { console.warn(e); canvas.hidden = true; return; }

  const buf = gl.createBuffer();
  const upload = () => {
    buildHammer();
    metalCount = metal.length / 9; matteCount = matte.length / 9; matteStart = metalStart + metalCount;
    all = new Float32Array([...lines, ...shadowSrc, ...metal, ...matte]);
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, all, gl.DYNAMIC_DRAW);
  };

  // ---------- matrices (column-major) ----------
  const perspective = (fov, asp, n, f) => {
    const t = 1 / Math.tan(fov / 2);
    return [t / asp, 0, 0, 0, 0, t, 0, 0, 0, 0, (f + n) / (n - f), -1, 0, 0, 2 * f * n / (n - f), 0];
  };
  const lookAt = (e, c, up) => {
    const z = norm(sub(e, c)), x = norm(cross(up, z)), y = cross(z, x);
    return [x[0], y[0], z[0], 0, x[1], y[1], z[1], 0, x[2], y[2], z[2], 0, -dot(x, e), -dot(y, e), -dot(z, e), 1];
  };
  const mul = (a, b) => {
    const o = new Array(16);
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++)
      o[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
    return o;
  };
  const I = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  const T = (x, y, z) => { const m = I.slice(); m[12] = x; m[13] = y; m[14] = z; return m; };
    const Rz = (a) => { const c = Math.cos(a), s = Math.sin(a); return [c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; };

  const Ry = (a) => { const c = Math.cos(a), s = Math.sin(a); return [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]; };
  const rad = (d) => (d * Math.PI) / 180;

  // ---------- palette (follows OS color scheme unless overridden) ----------
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const palette = () => {
    const sun = [Math.cos(rad(S.sunElevation)) * Math.cos(rad(S.sunAzimuth)), Math.sin(rad(S.sunElevation)), Math.cos(rad(S.sunElevation)) * Math.sin(rad(S.sunAzimuth))];
    return (S.theme === "auto" ? dark.matches : S.theme === "dark")
      ? { amb: [0.45, 0.5, 0.7], gnd: [0.1, 0.1, 0.16], grid: [0.35, 0.6, 0.85], sun }
      : { amb: [0.65, 0.7, 0.8], gnd: [0.4, 0.38, 0.36], grid: [0.3, 0.4, 0.6], sun };
  };

  // resting pose: head touching the ground, handle raised S.slant degrees
  let basePose = I, half = [1, 1];
  const updatePose = () => {
    const rest = Rz(Math.PI / 2 + rad(S.slant));
    let minY = Infinity, minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
    for (let i = metalStart; i < metalStart + metalCount + matteCount; i++) {
      const x = all[i * 9], y = all[i * 9 + 1], z = all[i * 9 + 2];
      const wx = rest[0] * x + rest[4] * y, wy = rest[1] * x + rest[5] * y;
      minY = Math.min(minY, wy); minX = Math.min(minX, wx); maxX = Math.max(maxX, wx);
      minZ = Math.min(minZ, z); maxZ = Math.max(maxZ, z);
    }
    basePose = mul(T(-(minX + maxX) / 2, -minY, 0), rest);
    half = [Math.max((maxX - minX) / 2 * 0.9, 0.8), Math.max((maxZ - minZ) * 0.9, 1.4)];
  };
  upload(); updatePose();

  // ---------- render ----------
  let w = 0, h = 0, visible = true, camAng = 0.5, yaw = 0, tAcc = 0, last = performance.now();

  const resize = () => {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    w = Math.round(canvas.clientWidth * dpr); h = Math.round(canvas.clientHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
  };

  const attrs = (p) => {
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    for (const [name, off] of [["aPos", 0], ["aNrm", 12], ["aCol", 24]]) {
      const l = gl.getAttribLocation(p, name);
      gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, 3, gl.FLOAT, false, 36, off);
    }
  };

  const frame = (now) => {
    requestAnimationFrame(frame);
    if (!visible) { last = now; return; }
    const dt = Math.min((now - last) / 1000, 0.1);
    last = now;
    if (S.orbit) camAng += dt * S.orbitSpeed;
    if (S.spin) yaw += dt * 0.6;
    resize();
    const pal = palette();
    gl.viewport(0, 0, w, h);
    gl.disable(gl.DEPTH_TEST); gl.disable(gl.BLEND);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    const eye = [Math.cos(camAng) * S.distance, S.height, Math.sin(camAng) * S.distance];
    const vp = mul(perspective(0.7, w / h, 0.5, 400), lookAt(eye, [0, 1.8, 0], [0, 1, 0]));

    gl.useProgram(sceneP);
    attrs(sceneP);
    const U = (n) => gl.getUniformLocation(sceneP, n);
    gl.uniformMatrix4fv(U("uVP"), false, vp);
    gl.uniform3fv(U("uSun"), pal.sun); gl.uniform3fv(U("uEye"), eye);
    gl.uniform3fv(U("uSkyAmb"), pal.amb);
    gl.uniform3fv(U("uGround"), pal.gnd); gl.uniform3fv(U("uGrid"), pal.grid);
    gl.uniform3f(U("uShadow"), half[0], half[1], yaw);
    gl.uniform1f(U("uGridAlpha"), S.gridOpacity);
    gl.uniform2f(U("uFade"), S.gridFade * 0.2, S.gridFade);
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);

    if (S.grid) {
      gl.uniformMatrix4fv(U("uModel"), false, [S.gridSpacing, 0, 0, 0, 0, 1, 0, 0, 0, 0, S.gridSpacing, 0, 0, 0, 0, 1]);
      gl.uniform1f(U("uMode"), 2);
      gl.drawArrays(gl.LINES, lineStart, lineCount);
    }
    if (S.shadow) {
      gl.uniformMatrix4fv(U("uModel"), false, I);
      gl.depthMask(false);
      gl.uniform1f(U("uMode"), 3);
      gl.drawArrays(gl.TRIANGLES, shadowStart, 6);
      gl.depthMask(true);
    }

    gl.uniformMatrix4fv(U("uModel"), false, mul(Ry(yaw), basePose));
    gl.uniform1f(U("uMode"), 1);
    gl.drawArrays(gl.TRIANGLES, metalStart, metalCount);
    gl.uniform1f(U("uMode"), 0);
    gl.drawArrays(gl.TRIANGLES, matteStart, matteCount);
  };


  // ---------- control panel ----------
  const stage = canvas.parentElement;
  const toggle = document.createElement("button");
  toggle.type = "button"; toggle.textContent = "\u00ab";
  toggle.setAttribute("aria-label", "Toggle controls"); toggle.setAttribute("aria-expanded", "false");
  const panel = document.createElement("aside");
  panel.hidden = true;
  toggle.onclick = () => {
    panel.hidden = !panel.hidden;
    toggle.textContent = panel.hidden ? "\u00ab" : "\u00bb";
    toggle.setAttribute("aria-expanded", String(!panel.hidden));
  };
  let uid = 0;
  const row = (label, input) => {
    const r = document.createElement("div");
    const l = document.createElement("label"); l.textContent = label;
    if (input.id) l.htmlFor = input.id;
    r.append(l, input); panel.append(r); return r;
  };
  const heading = (text) => { const h = document.createElement("h3"); h.textContent = text; panel.append(h); };
  const slider = (label, key, min, max, step, onChange) => {
    const i = document.createElement("input");
    i.type = "range"; i.id = "hc" + uid++; i.min = min; i.max = max; i.step = step; i.value = S[key];
    i.oninput = () => { S[key] = +i.value; onChange && onChange(); };
    row(label, i);
  };
  const rebuild = () => { upload(); updatePose(); };

  heading("Hammer");
  slider("Head length", "headLength", 0.8, 2.2, 0.05, rebuild);
  slider("Handle length", "handleLength", 2, 7, 0.1, rebuild);
  heading("Camera");
  slider("Orbit speed", "orbitSpeed", -0.6, 0.6, 0.01);
  slider("Distance", "distance", 7, 28, 0.5);
  slider("Height", "height", 0.5, 14, 0.1);
  heading("Light");
  slider("Sun direction", "sunAzimuth", 0, 360, 1);
  heading("Ground");
  slider("Spacing", "gridSpacing", 0.5, 2.5, 0.05);
  slider("Opacity", "gridOpacity", 0.1, 1, 0.01);
  slider("Fade distance", "gridFade", 10, 50, 1);
  stage.append(panel, toggle);

  new IntersectionObserver((e) => { visible = e[0].isIntersecting; }).observe(canvas);
  requestAnimationFrame(frame);
})();
