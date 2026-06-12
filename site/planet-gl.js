// planet-gl.js — WebGL renderer for the atlas's document planets.
//
// All of the "documents are planets seen from orbit" whimsy lives here,
// behind a two-method interface (begin/draw), so atlas.js stays a plain 2D
// canvas app: it composites this renderer's canvas into its own each frame
// and falls back to its 2D strip projection when WebGL isn't available.
//
// The fragment shader treats each planet quad as a ray-traced lit sphere:
// procedural fbm terrain seeded per document, polar caps, a day/night
// terminator with specular glint, an atmosphere rim in the publication's
// accent color — and the document's info texture rendered as emissive city
// lights, glowing brightest on the night side.
(function() {
  'use strict';

  var VERT = [
    'attribute vec2 aPos;',
    'uniform vec2 uRes;',
    'uniform vec2 uCenter;',
    'uniform float uRadius;',
    'uniform float uMargin;',
    'varying vec2 vP;',
    'void main() {',
    '  vP = aPos * uMargin;',
    // +y up in sphere space; screen y grows down
    '  vec2 px = uCenter + vec2(aPos.x, -aPos.y) * uRadius * uMargin;',
    '  vec2 clip = (px / uRes) * 2.0 - 1.0;',
    '  gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);',
    '}',
  ].join('\n');

  var FRAG = [
    '#ifdef GL_FRAGMENT_PRECISION_HIGH',
    'precision highp float;',
    '#else',
    'precision mediump float;',
    '#endif',
    'varying vec2 vP;',
    'uniform sampler2D uTex;',
    'uniform float uRot, uTilt, uAlpha, uSeed, uTexSpan, uHover, uDark, uPx, uMargin, uLift;',
    'uniform vec3 uBase, uAccent;',

    'float hash3(vec3 p) {',
    '  p = fract(p * 0.3183099 + 0.1) + uSeed * 0.013;',
    '  p *= 17.0;',
    '  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));',
    '}',
    'float noise3(vec3 x) {',
    '  vec3 i = floor(x), f = fract(x);',
    '  f = f * f * (3.0 - 2.0 * f);',
    '  return mix(',
    '    mix(mix(hash3(i), hash3(i + vec3(1,0,0)), f.x),',
    '        mix(hash3(i + vec3(0,1,0)), hash3(i + vec3(1,1,0)), f.x), f.y),',
    '    mix(mix(hash3(i + vec3(0,0,1)), hash3(i + vec3(1,0,1)), f.x),',
    '        mix(hash3(i + vec3(0,1,1)), hash3(i + vec3(1,1,1)), f.x), f.y), f.z);',
    '}',
    'float fbm(vec3 p) {',
    '  float v = 0.5 * noise3(p);',
    '  p = p * 2.03 + 11.3; v += 0.275 * noise3(p);',
    '  p = p * 2.03 + 11.3; v += 0.151 * noise3(p);',
    '  p = p * 2.03 + 11.3; v += 0.083 * noise3(p);',
    '  return v;',
    '}',

    'void main() {',
    '  float r = length(vP);',
    '  vec4 outc = vec4(0.0);',
    '  float ct = cos(uTilt), st = sin(uTilt);',
    // the info shell: billboards in orbit, a few percent above the surface —
    // they float over the terrain and hang past the limb into space
    '  vec4 em = vec4(0.0);',
    '  if (r < uLift) {',
    '    float zt = sqrt(uLift * uLift - r * r);',
    '    vec3 Nb = vec3(vP, zt) / uLift;',
    '    vec3 Nbt = vec3(Nb.x, Nb.y * ct + Nb.z * st, -Nb.y * st + Nb.z * ct);',
    '    float latB = asin(clamp(Nbt.y, -1.0, 1.0));',
    '    float lonB = atan(Nbt.x, Nbt.z) + uRot;',
    '    em = texture2D(uTex, vec2(fract(lonB * 0.15915494) * uTexSpan, clamp(0.5 - latB * 0.31830988, 0.0, 1.0)));',
    '    em.a *= smoothstep(uLift, uLift - 6.0 * uPx, r);',
    '  }',
    '  if (r < 1.0) {',
    '    float z = sqrt(1.0 - r * r);',
    '    vec3 N = vec3(vP, z);',
    // tilt: we orbit slightly north of the equator, so the equator dips
    '    vec3 Nt = vec3(N.x, N.y * ct + N.z * st, -N.y * st + N.z * ct);',
    '    float lat = asin(clamp(Nt.y, -1.0, 1.0));',
    '    float lon = atan(Nt.x, Nt.z) + uRot;',
    // terrain in the planet-fixed frame so it spins with the surface
    '    vec3 P = vec3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));',
    '    float terr = fbm(P * 2.8);',
    '    float terr2 = fbm(P * 6.1 + 31.7);',
    '    vec3 land = mix(uBase * 0.45, uBase * 1.4, smoothstep(0.32, 0.68, terr));',
    '    land = mix(land, uAccent * 0.6, smoothstep(0.56, 0.78, terr2) * 0.5);',
    '    float cap = smoothstep(0.78, 0.94, abs(sin(lat)) + (terr2 - 0.5) * 0.15);',
    '    land = mix(land, vec3(0.82, 0.88, 0.94), cap * 0.65);',
    // lighting: sun upper-left, soft terminator
    '    vec3 L = normalize(vec3(-0.5, 0.45, 0.62));',
    '    float ndl = dot(N, L);',
    '    float day = smoothstep(-0.12, 0.3, ndl);',
    '    float ambient = mix(0.55, 0.10, uDark);',
    '    vec3 surf = land * (ambient + (1.0 - ambient) * max(ndl, 0.0));',
    '    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));',
    '    surf += uAccent * pow(max(dot(N, H), 0.0), 70.0) * 0.4 * day;',
    // atmosphere hugging the limb
    '    float fres = pow(1.0 - z, 2.2);',
    '    surf += uAccent * fres * (0.55 + uHover * 0.5);',
    // the orbital billboards over the surface: emissive, brightest at night
    '    float emBoost = mix(1.0, mix(1.7, 1.1, day), uDark);',
    '    surf = mix(surf, em.rgb * emBoost, em.a * 0.95);',
    '    surf += em.rgb * em.a * 0.4 * (1.0 - day) * uDark;',
    '    float edge = smoothstep(1.0, 1.0 - 3.0 * uPx, r);',
    '    outc = vec4(surf, edge);',
    '  } else {',
    // past the limb: atmosphere halo, with billboards hanging into space
    '    float d = (r - 1.0) / (uMargin - 1.0);',
    '    float glow = pow(max(1.0 - d, 0.0), 2.6);',
    '    vec3 col = uAccent * (0.8 + 0.4 * glow);',
    '    float a = glow * (0.32 + uHover * 0.28);',
    '    float billBoost = mix(1.0, 1.45, uDark);',
    '    col = mix(col, em.rgb * billBoost, em.a);',
    '    a = max(a, em.a * 0.95);',
    '    outc = vec4(col, a);',
    '  }',
    '  gl_FragColor = vec4(outc.rgb, outc.a * uAlpha);',
    '}',
  ].join('\n');

  function compile(gl, type, src) {
    var sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      throw new Error(gl.getShaderInfoLog(sh) || 'shader compile failed');
    }
    return sh;
  }

  window.PlanetGL = {
    create: function() {
      try {
        var canvas = document.createElement('canvas');
        var gl = canvas.getContext('webgl', { alpha: true, premultipliedAlpha: false })
          || canvas.getContext('experimental-webgl', { alpha: true, premultipliedAlpha: false });
        if (!gl) return null;

        var prog = gl.createProgram();
        gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
        gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
        gl.linkProgram(prog);
        if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
          throw new Error(gl.getProgramInfoLog(prog) || 'link failed');
        }

        var buf = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, buf);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

        var U = {};
        ['uRes', 'uCenter', 'uRadius', 'uMargin', 'uTex', 'uRot', 'uTilt', 'uAlpha',
         'uSeed', 'uTexSpan', 'uHover', 'uDark', 'uPx', 'uBase', 'uAccent', 'uLift'].forEach(function(n) {
          U[n] = gl.getUniformLocation(prog, n);
        });
        var aPos = gl.getAttribLocation(prog, 'aPos');

        var MARGIN = 1.35;
        // GL textures keyed by their source canvas — atlas.js rebuilds the
        // canvas object on theme/accent change, so stale entries just get
        // garbage-collected with the old canvas
        var texCache = new WeakMap();

        function getTex(cv) {
          var t = texCache.get(cv);
          if (t) return t;
          t = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, t);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, cv);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
          texCache.set(cv, t);
          return t;
        }

        return {
          canvas: canvas,
          begin: function(W, H, dpr, dark) {
            var bw = Math.round(W * dpr), bh = Math.round(H * dpr);
            if (canvas.width !== bw || canvas.height !== bh) {
              canvas.width = bw;
              canvas.height = bh;
            }
            gl.viewport(0, 0, bw, bh);
            gl.clearColor(0, 0, 0, 0);
            gl.clear(gl.COLOR_BUFFER_BIT);
            gl.useProgram(prog);
            gl.enable(gl.BLEND);
            gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
            gl.bindBuffer(gl.ARRAY_BUFFER, buf);
            gl.enableVertexAttribArray(aPos);
            gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);
            gl.activeTexture(gl.TEXTURE0);
            gl.uniform1i(U.uTex, 0);
            gl.uniform2f(U.uRes, W, H);
            gl.uniform1f(U.uDark, dark ? 1 : 0);
            gl.uniform1f(U.uMargin, MARGIN);
            gl.uniform1f(U.uTilt, 0.35);
            gl.uniform1f(U.uLift, 1.08);
          },
          // opts: {base:[r,g,b 0-1], accent:[r,g,b 0-1], seed, texSpan, hover, dpr}
          draw: function(texCanvas, sx, sy, R, alpha, rot, opts) {
            gl.bindTexture(gl.TEXTURE_2D, getTex(texCanvas));
            gl.uniform2f(U.uCenter, sx, sy);
            gl.uniform1f(U.uRadius, R);
            gl.uniform1f(U.uRot, rot);
            gl.uniform1f(U.uAlpha, alpha);
            gl.uniform1f(U.uSeed, opts.seed || 0);
            gl.uniform1f(U.uTexSpan, opts.texSpan || 0.8);
            gl.uniform1f(U.uHover, opts.hover ? 1 : 0);
            gl.uniform1f(U.uPx, 1 / Math.max(8, R * (opts.dpr || 1)));
            gl.uniform3f(U.uBase, opts.base[0], opts.base[1], opts.base[2]);
            gl.uniform3f(U.uAccent, opts.accent[0], opts.accent[1], opts.accent[2]);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
          },
        };
      } catch (e) {
        return null;
      }
    },
  };
})();
