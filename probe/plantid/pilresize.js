// open_clip's image preprocessing, reproduced bit-for-bit in JS:
//   torchvision Resize(224, bicubic) on a PIL image  → Pillow's two-pass
//   antialiased bicubic (a = -0.5, 22-bit fixed point, horizontal pass first,
//   uint8 between passes), then CenterCrop(224) and Normalize(mean, std).
// Matching Pillow exactly matters: a canvas drawImage downscale gave
// embeddings only ~0.97–0.99 cosine to the laptop's, enough to flip close
// calls. Checked against Pillow by pipeline/plantid/check_pilresize.py.

const PB = 22;  // Pillow PRECISION_BITS = 32 - 8 - 2

function bicubic(x) {
  const a = -0.5;
  x = Math.abs(x);
  if (x < 1) return ((a + 2) * x - (a + 3)) * x * x + 1;
  if (x < 2) return (((x - 5) * x + 8) * x - 4) * a;
  return 0;
}

// Pillow precompute_coeffs + normalize_coeffs_8bpc (box = whole image)
function coeffs(inSize, outSize) {
  const scale = inSize / outSize;
  const filterscale = Math.max(scale, 1);
  const support = 2 * filterscale;
  const ksize = Math.ceil(support) * 2 + 1;
  const kk = new Int32Array(outSize * ksize), bounds = new Int32Array(outSize * 2);
  const pre = new Float64Array(ksize);
  for (let xx = 0; xx < outSize; xx++) {
    const center = (xx + 0.5) * scale;
    const ss = 1 / filterscale;
    let xmin = Math.trunc(center - support + 0.5);
    if (xmin < 0) xmin = 0;
    let xmax = Math.trunc(center + support + 0.5);
    if (xmax > inSize) xmax = inSize;
    xmax -= xmin;
    let ww = 0;
    for (let x = 0; x < xmax; x++) { const w = bicubic((x + xmin - center + 0.5) * ss); pre[x] = w; ww += w; }
    for (let x = 0; x < xmax; x++) {
      const v = ww !== 0 ? pre[x] / ww : pre[x];
      kk[xx * ksize + x] = Math.trunc(v < 0 ? -0.5 + v * (1 << PB) : 0.5 + v * (1 << PB));
    }
    bounds[xx * 2] = xmin; bounds[xx * 2 + 1] = xmax;
  }
  return { ksize, kk, bounds };
}

const clip8 = (ss) => { const v = Math.floor(ss / (1 << PB)); return v < 0 ? 0 : v > 255 ? 255 : v; };

/** RGBA (or RGB with stride 3) w×h → RGB nw×nh, exactly like Pillow's
 *  Image.resize((nw, nh), BICUBIC) on an RGB image. */
export function pilResize(src, w, h, nw, nh, stride = 4) {
  const H = coeffs(w, nw), V = coeffs(h, nh);
  // rows of the source the vertical pass will read
  const yFirst = V.bounds[0], yLast = V.bounds[(nh - 1) * 2] + V.bounds[(nh - 1) * 2 + 1];
  const th = yLast - yFirst;
  let tmp, tw = nw;
  if (nw !== w) {
    tmp = new Uint8Array(nw * th * 3);
    for (let y = 0; y < th; y++) {
      const row = (y + yFirst) * w * stride;
      for (let xx = 0; xx < nw; xx++) {
        const xmin = H.bounds[xx * 2], xmax = H.bounds[xx * 2 + 1], ko = xx * H.ksize;
        let s0 = 1 << (PB - 1), s1 = s0, s2 = s0;
        for (let x = 0; x < xmax; x++) {
          const k = H.kk[ko + x], p = row + (x + xmin) * stride;
          s0 += src[p] * k; s1 += src[p + 1] * k; s2 += src[p + 2] * k;
        }
        const o = (y * nw + xx) * 3;
        tmp[o] = clip8(s0); tmp[o + 1] = clip8(s1); tmp[o + 2] = clip8(s2);
      }
    }
  } else {  // no horizontal pass: copy the needed rows as RGB
    tmp = new Uint8Array(w * th * 3);
    for (let y = 0; y < th; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 3; c++)
      tmp[(y * w + x) * 3 + c] = src[((y + yFirst) * w + x) * stride + c];
  }
  if (nh === h) return tmp;  // th === h here
  const out = new Uint8Array(nw * nh * 3);
  for (let yy = 0; yy < nh; yy++) {
    const ymin = V.bounds[yy * 2] - yFirst, ymax = V.bounds[yy * 2 + 1], ko = yy * V.ksize;
    for (let xx = 0; xx < tw; xx++) {
      let s0 = 1 << (PB - 1), s1 = s0, s2 = s0;
      for (let y = 0; y < ymax; y++) {
        const k = V.kk[ko + y], p = ((y + ymin) * tw + xx) * 3;
        s0 += tmp[p] * k; s1 += tmp[p + 1] * k; s2 += tmp[p + 2] * k;
      }
      const o = (yy * nw + xx) * 3;
      out[o] = clip8(s0); out[o + 1] = clip8(s1); out[o + 2] = clip8(s2);
    }
  }
  return out;
}

const pyRound = (x) => {  // Python's round(): halves go to the even neighbour
  const f = Math.floor(x), d = x - f;
  return d > 0.5 || (d === 0.5 && f % 2 !== 0) ? f + 1 : f;
};

/** torchvision Resize(S) + CenterCrop(S) → uint8 RGB S×S. */
export function resizeCrop(src, w, h, S = 224, stride = 4) {
  const [nw, nh] = w <= h ? [S, Math.trunc(S * h / w)] : [Math.trunc(S * w / h), S];
  const r = pilResize(src, w, h, nw, nh, stride);
  const top = pyRound((nh - S) / 2), left = pyRound((nw - S) / 2);
  const out = new Uint8Array(S * S * 3);
  for (let y = 0; y < S; y++) out.set(r.subarray(((y + top) * nw + left) * 3, ((y + top) * nw + left + S) * 3), y * S * 3);
  return out;
}

/** uint8 RGB S×S → normalised CHW float32, as open_clip's ToTensor + Normalize. */
export function normalise(rgb, S, mean, std) {
  const n = S * S, out = new Float32Array(3 * n);
  for (let i = 0; i < n; i++) for (let c = 0; c < 3; c++)
    out[c * n + i] = (rgb[i * 3 + c] / 255 - mean[c]) / std[c];
  return out;
}
