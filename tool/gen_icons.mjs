// InkPaper 图标生成脚本（零依赖，仅用 Node 内置 zlib）
// 用法: node tool/gen_icons.mjs [master.png]
// 默认母版: docs/picture/logo_v2.png（1024x1024）
// 输出: iOS AppIcon.appiconset / Android mipmap-* / Android 自适应图标前景层
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';

const ROOT = path.resolve(import.meta.dirname, '..');
const MASTER = path.resolve(ROOT, process.argv[2] ?? 'docs/picture/logo_v2.png');

/* ---------------- PNG 解码 ---------------- */
function decodePNG(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error('不是 PNG 文件');
  let pos = 8;
  let width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
  let palette = null, trns = null;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos); pos += 4;
    const type = buf.toString('ascii', pos, pos + 4); pos += 4;
    const data = buf.subarray(pos, pos + len); pos += len + 4;
    if (type === 'IHDR') {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      bitDepth = data[8]; colorType = data[9]; interlace = data[12];
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'PLTE') palette = data;
    else if (type === 'tRNS') trns = data;
    else if (type === 'IEND') break;
  }
  if (bitDepth !== 8) throw new Error(`只支持 8bit，当前 ${bitDepth}`);
  if (interlace !== 0) throw new Error('不支持隔行扫描 PNG');

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
  if (!channels) throw new Error(`不支持的 colorType ${colorType}`);
  const stride = width * channels;
  const out = new Uint8Array(width * height * 4);
  const prev = new Uint8Array(stride);
  const cur = new Uint8Array(stride);
  let p = 0;

  for (let y = 0; y < height; y++) {
    const ft = raw[p++];
    cur.set(raw.subarray(p, p + stride)); p += stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? cur[x - channels] : 0;
      const b = prev[x];
      const c = x >= channels ? prev[x - channels] : 0;
      let v = cur[x];
      if (ft === 1) v = (v + a) & 255;
      else if (ft === 2) v = (v + b) & 255;
      else if (ft === 3) v = (v + ((a + b) >> 1)) & 255;
      else if (ft === 4) {
        const pp = a + b - c;
        const pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
        v = (v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 255;
      } else if (ft !== 0) throw new Error(`未知过滤类型 ${ft}`);
      cur[x] = v;
    }
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      if (colorType === 6) {
        out[o] = cur[x * 4]; out[o + 1] = cur[x * 4 + 1];
        out[o + 2] = cur[x * 4 + 2]; out[o + 3] = cur[x * 4 + 3];
      } else if (colorType === 2) {
        out[o] = cur[x * 3]; out[o + 1] = cur[x * 3 + 1];
        out[o + 2] = cur[x * 3 + 2]; out[o + 3] = 255;
      } else if (colorType === 0) {
        out[o] = out[o + 1] = out[o + 2] = cur[x]; out[o + 3] = 255;
      } else if (colorType === 4) {
        out[o] = out[o + 1] = out[o + 2] = cur[x * 2]; out[o + 3] = cur[x * 2 + 1];
      } else {
        const i = cur[x] * 3;
        out[o] = palette[i]; out[o + 1] = palette[i + 1]; out[o + 2] = palette[i + 2];
        out[o + 3] = trns && cur[x] < trns.length ? trns[cur[x]] : 255;
      }
    }
    prev.set(cur);
  }
  return { width, height, data: out };
}

/* ---------------- PNG 编码 ---------------- */
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 255] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePNG({ width, height, data }, opaque = false) {
  const ch = opaque ? 3 : 4;
  const stride = width * ch;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    for (let x = 0; x < width; x++) {
      const s = (y * width + x) * 4;
      const d = y * (stride + 1) + 1 + x * ch;
      raw[d] = data[s]; raw[d + 1] = data[s + 1]; raw[d + 2] = data[s + 2];
      if (!opaque) raw[d + 3] = data[s + 3];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = opaque ? 2 : 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/* ---------------- 缩放（缩小用面积平均，放大用 Catmull-Rom 双三次） ---------------- */
const clamp255 = (v) => (v < 0 ? 0 : v > 255 ? 255 : Math.round(v));

function crWeights(t) {
  const t2 = t * t, t3 = t2 * t;
  return [
    -0.5 * t3 + t2 - 0.5 * t,
    1.5 * t3 - 2.5 * t2 + 1,
    -1.5 * t3 + 2 * t2 + 0.5 * t,
    0.5 * t3 - 0.5 * t2,
  ];
}

function resizeUp(src, sw, sh, dw, dh) {
  const out = new Uint8Array(dw * dh * 4);
  const sx = sw / dw, sy = sh / dh;
  for (let y = 0; y < dh; y++) {
    const fy = (y + 0.5) * sy - 0.5;
    const y0 = Math.floor(fy);
    const wy = crWeights(fy - y0);
    for (let x = 0; x < dw; x++) {
      const fx = (x + 0.5) * sx - 0.5;
      const x0 = Math.floor(fx);
      const wx = crWeights(fx - x0);
      let r = 0, g = 0, b = 0, a = 0;
      for (let j = 0; j < 4; j++) {
        const yy = Math.min(sh - 1, Math.max(0, y0 - 1 + j));
        for (let i = 0; i < 4; i++) {
          const xx = Math.min(sw - 1, Math.max(0, x0 - 1 + i));
          const w = wx[i] * wy[j];
          const o = (yy * sw + xx) * 4;
          const al = src[o + 3] / 255;
          r += src[o] * al * w; g += src[o + 1] * al * w; b += src[o + 2] * al * w;
          a += src[o + 3] * w;
        }
      }
      const d = (y * dw + x) * 4;
      if (a > 0) {
        const k = 255 / a;
        out[d] = clamp255(r * k); out[d + 1] = clamp255(g * k); out[d + 2] = clamp255(b * k);
      }
      out[d + 3] = clamp255(a);
    }
  }
  return out;
}

function resize(src, sw, sh, dw, dh) {
  if (sw === dw && sh === dh) return new Uint8Array(src);
  if (dw > sw || dh > sh) return resizeUp(src, sw, sh, dw, dh);
  const out = new Uint8Array(dw * dh * 4);
  const scaleX = sw / dw, scaleY = sh / dh;
  for (let y = 0; y < dh; y++) {
    const sy0 = y * scaleY, sy1 = (y + 1) * scaleY;
    const iy0 = Math.floor(sy0), iy1 = Math.min(sh, Math.ceil(sy1));
    for (let x = 0; x < dw; x++) {
      const sx0 = x * scaleX, sx1 = (x + 1) * scaleX;
      const ix0 = Math.floor(sx0), ix1 = Math.min(sw, Math.ceil(sx1));
      let r = 0, g = 0, b = 0, a = 0, wsum = 0;
      for (let yy = iy0; yy < iy1; yy++) {
        const wy = Math.min(yy + 1, sy1) - Math.max(yy, sy0);
        if (wy <= 0) continue;
        for (let xx = ix0; xx < ix1; xx++) {
          const wx = Math.min(xx + 1, sx1) - Math.max(xx, sx0);
          if (wx <= 0) continue;
          const w = wx * wy;
          const o = (yy * sw + xx) * 4;
          const al = src[o + 3] / 255;
          r += src[o] * al * w; g += src[o + 1] * al * w; b += src[o + 2] * al * w;
          a += src[o + 3] * w; wsum += w;
        }
      }
      const d = (y * dw + x) * 4;
      if (a > 0) {
        const k = 255 / a;
        out[d] = Math.round(r * k); out[d + 1] = Math.round(g * k); out[d + 2] = Math.round(b * k);
      }
      out[d + 3] = Math.round(a / wsum);
    }
  }
  return out;
}

/* ---------------- 主流程 ---------------- */
const master = decodePNG(fs.readFileSync(MASTER));
console.log(`母版: ${path.relative(ROOT, MASTER)} ${master.width}x${master.height}`);

// 采样四角求背景色
function sampleCorner(img, cx, cy, size = 32) {
  let r = 0, g = 0, b = 0, n = 0;
  for (let y = cy; y < cy + size; y++) {
    for (let x = cx; x < cx + size; x++) {
      const o = (y * img.width + x) * 4;
      r += img.data[o]; g += img.data[o + 1]; b += img.data[o + 2]; n++;
    }
  }
  return [Math.round(r / n), Math.round(g / n), Math.round(b / n)];
}
const corners = [
  sampleCorner(master, 0, 0),
  sampleCorner(master, master.width - 32, 0),
  sampleCorner(master, 0, master.height - 32),
  sampleCorner(master, master.width - 32, master.height - 32),
];
const bg = [0, 1, 2].map((i) => Math.round(corners.reduce((s, c) => s + c[i], 0) / 4));
const hex = '#' + bg.map((v) => v.toString(16).padStart(2, '0').toUpperCase()).join('');
console.log(`背景色: rgb(${bg.join(',')}) = ${hex}`);

// 背景噪声评估（决定抠图阈值）
let maxNoise = 0;
for (let y = 0; y < 32; y++) {
  for (let x = 0; x < master.width; x++) {
    const o = (y * master.width + x) * 4;
    const d = Math.hypot(master.data[o] - bg[0], master.data[o + 1] - bg[1], master.data[o + 2] - bg[2]);
    if (d > maxNoise) maxNoise = d;
  }
}
console.log(`顶部边缘背景最大偏差: ${maxNoise.toFixed(1)}`);

// 内容包围盒（色差 > 20 视为内容），用于确认留白比例
let bx0 = master.width, by0 = master.height, bx1 = -1, by1 = -1;
for (let y = 0; y < master.height; y++) {
  for (let x = 0; x < master.width; x++) {
    const o = (y * master.width + x) * 4;
    const d = Math.hypot(master.data[o] - bg[0], master.data[o + 1] - bg[1], master.data[o + 2] - bg[2]);
    if (d > 20) {
      if (x < bx0) bx0 = x;
      if (x > bx1) bx1 = x;
      if (y < by0) by0 = y;
      if (y > by1) by1 = y;
    }
  }
}
if (bx1 > 0) {
  const pct = (v, total) => ((v / total) * 100).toFixed(1);
  console.log(
    `内容包围盒: x ${pct(bx0, master.width)}%~${pct(bx1 / master.width, 1)}% ` +
      `y ${pct(by0, master.height)}%~${pct(by1 / master.height, 1)}%`,
  );
} else {
  console.log('警告: 未检测到内容，母版可能是单色');
}

/* 1. iOS 图标（不透明 RGB） */
const iosDir = path.join(ROOT, 'ios/Runner/Assets.xcassets/AppIcon.appiconset');
const iosIcons = {
  'Icon-App-20x20@1x.png': 20,
  'Icon-App-20x20@2x.png': 40,
  'Icon-App-20x20@3x.png': 60,
  'Icon-App-29x29@1x.png': 29,
  'Icon-App-29x29@2x.png': 58,
  'Icon-App-29x29@3x.png': 87,
  'Icon-App-40x40@1x.png': 40,
  'Icon-App-40x40@2x.png': 80,
  'Icon-App-40x40@3x.png': 120,
  'Icon-App-60x60@2x.png': 120,
  'Icon-App-60x60@3x.png': 180,
  'Icon-App-76x76@1x.png': 76,
  'Icon-App-76x76@2x.png': 152,
  'Icon-App-83.5x83.5@2x.png': 167,
  'Icon-App-1024x1024@1x.png': 1024,
};
let n = 0;
for (const [name, size] of Object.entries(iosIcons)) {
  const data = resize(master.data, master.width, master.height, size, size);
  fs.writeFileSync(path.join(iosDir, name), encodePNG({ width: size, height: size, data }, true));
  n++;
}
console.log(`iOS: ${n} 张`);

/* 2. Android 传统图标 */
const mipmaps = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
for (const [dens, size] of Object.entries(mipmaps)) {
  const data = resize(master.data, master.width, master.height, size, size);
  fs.writeFileSync(
    path.join(ROOT, `android/app/src/main/res/mipmap-${dens}/ic_launcher.png`),
    encodePNG({ width: size, height: size, data }, true),
  );
}
console.log(`Android 传统图标: ${Object.keys(mipmaps).length} 张`);

/* 3. Android 自适应图标前景层
   108dp 画布，内容缩放至中间 72dp（安全区），四周透明。
   抠图规则：只有「与画布边缘连通的背景色像素」才透明，
   这样被主体包住的白纸/浅色区域不会被误判成背景而挖空。 */
const fgSizes = { mdpi: 108, hdpi: 162, xhdpi: 216, xxhdpi: 324, xxxhdpi: 432 };
// 108dp 画布里内容的占位边长：母版主体只占中间约 68%，故取 96dp 让主体接近 66dp 安全圆，
// 既不浪费留白，也不会被启动器遮罩裁掉。
const CONTENT_DP = 96;
const T0 = Math.max(18, maxNoise + 8); // 低于此色差视为背景色
const MW = master.width, MH = master.height;
const dist = new Float32Array(MW * MH);
const bgLike = new Uint8Array(MW * MH);
for (let p = 0; p < MW * MH; p++) {
  const o = p * 4;
  const d = Math.hypot(
    master.data[o] - bg[0], master.data[o + 1] - bg[1], master.data[o + 2] - bg[2],
  );
  dist[p] = d;
  bgLike[p] = d < T0 ? 1 : 0;
}
// 从四条边向内做洪泛，标记真正的「外部背景」
const outside = new Uint8Array(MW * MH);
const stack = new Int32Array(MW * MH);
let sp = 0;
const spread = (p) => {
  if (!outside[p] && bgLike[p]) { outside[p] = 1; stack[sp++] = p; }
};
for (let x = 0; x < MW; x++) { spread(x); spread((MH - 1) * MW + x); }
for (let y = 0; y < MH; y++) { spread(y * MW); spread(y * MW + MW - 1); }
while (sp > 0) {
  const p = stack[--sp];
  const x = p % MW, y = (p - x) / MW;
  if (x > 0) spread(p - 1);
  if (x < MW - 1) spread(p + 1);
  if (y > 0) spread(p - MW);
  if (y < MH - 1) spread(p + MW);
}

const keyed = new Uint8Array(MW * MH * 4);
let opaquePx = 0;
for (let p = 0; p < MW * MH; p++) {
  const o = p * 4;
  keyed[o] = master.data[o]; keyed[o + 1] = master.data[o + 1]; keyed[o + 2] = master.data[o + 2];
  if (outside[p]) {
    keyed[o + 3] = 0;
  } else {
    keyed[o + 3] = 255;
    opaquePx++;
  }
}
console.log(`抠图: 前景占比 ${((opaquePx / (MW * MH)) * 100).toFixed(1)}%`);

for (const [dens, size] of Object.entries(fgSizes)) {
  const content = Math.round((size * CONTENT_DP) / 108);
  const scaled = resize(keyed, master.width, master.height, content, content);
  const canvas = new Uint8Array(size * size * 4);
  const off = Math.round((size - content) / 2);
  for (let y = 0; y < content; y++) {
    for (let x = 0; x < content; x++) {
      const s = (y * content + x) * 4;
      const d = ((y + off) * size + (x + off)) * 4;
      canvas[d] = scaled[s]; canvas[d + 1] = scaled[s + 1];
      canvas[d + 2] = scaled[s + 2]; canvas[d + 3] = scaled[s + 3];
    }
  }
  fs.writeFileSync(
    path.join(ROOT, `android/app/src/main/res/drawable-${dens}/ic_launcher_foreground.png`),
    encodePNG({ width: size, height: size, data: canvas }, false),
  );
}
console.log(`Android 自适应前景: ${Object.keys(fgSizes).length} 张`);

/* 4. 预览图：圆/方圆遮罩下合成自适应图标，便于肉眼校验（写入系统临时目录，不入库） */
const pvSize = 432;
const pvContent = Math.round((pvSize * CONTENT_DP) / 108);
const pvScaled = resize(keyed, master.width, master.height, pvContent, pvContent);
const pv = new Uint8Array(pvSize * pvSize * 4);
const pvOff = Math.round((pvSize - pvContent) / 2);
for (let y = 0; y < pvSize; y++) {
  for (let x = 0; x < pvSize; x++) {
    const d = (y * pvSize + x) * 4;
    pv[d] = bg[0]; pv[d + 1] = bg[1]; pv[d + 2] = bg[2]; pv[d + 3] = 255;
  }
}
for (let y = 0; y < pvContent; y++) {
  for (let x = 0; x < pvContent; x++) {
    const s = (y * pvContent + x) * 4;
    const d = ((y + pvOff) * pvSize + (x + pvOff)) * 4;
    const a = pvScaled[s + 3] / 255;
    for (let c = 0; c < 3; c++) pv[d + c] = Math.round(pvScaled[s + c] * a + bg[c] * (1 - a));
    pv[d + 3] = 255;
  }
}
// 圆形遮罩（模拟启动器圆形图标）
const circle = new Uint8Array(pvSize * pvSize * 4);
const r = pvSize / 2;
for (let y = 0; y < pvSize; y++) {
  for (let x = 0; x < pvSize; x++) {
    const d = (y * pvSize + x) * 4;
    const inside = Math.hypot(x + 0.5 - r, y + 0.5 - r) <= r - 1;
    circle[d] = pv[d]; circle[d + 1] = pv[d + 1]; circle[d + 2] = pv[d + 2];
    circle[d + 3] = inside ? 255 : 0;
  }
}
const pvPath = path.join(os.tmpdir(), 'inkpaper_icon_preview.png');
fs.writeFileSync(pvPath, encodePNG({ width: pvSize, height: pvSize, data: circle }, false));
console.log(`自适应图标预览: ${pvPath}`);
console.log(`\nic_launcher_background 应为 ${hex}`);
