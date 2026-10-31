#!/usr/bin/env python3
# Turn a FIMC-LITE RAW10 frame (one 16-bit word per pixel) into a PNG. Test tool.
#   raw2png.py FRAME WIDTH HEIGHT OUT.png [bayer] [stride-bytes] [shift]
import array, sys
from PIL import Image

src, w, h, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
bayer = sys.argv[5] if len(sys.argv) > 5 else 'grbg'
stride = int(sys.argv[6]) if len(sys.argv) > 6 else w * 2
shift = int(sys.argv[7]) if len(sys.argv) > 7 else 0
a = array.array('H')
with open(src, 'rb') as f:
    a.frombytes(f.read(stride * h))
sw = stride // 2
vals = sorted(a[i] for i in range(0, len(a), 257))
print('min', vals[0], 'p50', vals[len(vals) // 2], 'p99', vals[len(vals) * 99 // 100], 'max', vals[-1],
      'marker words', sum(1 for i in range(0, len(a), 257) if a[i] == 0x5a5a), 'of', len(vals))
black = vals[len(vals) // 200] >> shift
pos = {c: [] for c in 'rgb'}
for y in range(2):
    for x in range(2):
        pos[bayer[y * 2 + x]].append(y * sw + x)
h2, w2 = h // 2, w // 2
R, G, B = [0.0] * (w2 * h2), [0.0] * (w2 * h2), [0.0] * (w2 * h2)
for y in range(h2):
    base = y * 2 * sw
    for x in range(w2):
        o = base + x * 2
        i = y * w2 + x
        R[i] = (a[o + pos['r'][0]] >> shift) - black
        G[i] = ((a[o + pos['g'][0]] >> shift) + (a[o + pos['g'][1]] >> shift)) / 2 - black
        B[i] = (a[o + pos['b'][0]] >> shift) - black
mr, mg, mb = sum(R) / len(R), sum(G) / len(G), sum(B) / len(B)
print('means', round(mr, 1), round(mg, 1), round(mb, 1))
kr, kb = mg / max(mr, 1), mg / max(mb, 1)
top = sorted(G)[len(G) * 995 // 1000] or 1
lut = [min(255, int(255 * (i / 1024) ** (1 / 2.2))) for i in range(1025)]
def px(v):
    return lut[max(0, min(1024, int(v * 1024 / top)))]
buf = bytearray(w2 * h2 * 3)
for i in range(w2 * h2):
    buf[i * 3] = px(R[i] * kr)
    buf[i * 3 + 1] = px(G[i])
    buf[i * 3 + 2] = px(B[i] * kb)
Image.frombytes('RGB', (w2, h2), bytes(buf)).save(out)
print('wrote', out, w2, h2)
