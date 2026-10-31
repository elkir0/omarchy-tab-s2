#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""1 kHz detector for call audio checks (modem/audio/call-audio-check.sh).

    wavfine.py FILE START END [STEP]

Prints one character per STEP seconds of the left channel: T (1 kHz holds more
than 80 % of the energy), t (more than 40 %), s (other sound), _ (quiet),
. (digital zero). No audio content is printed."""
import math, struct, sys, wave
w = wave.open(sys.argv[1]); rate = w.getframerate(); ch = w.getnchannels()
a, b = float(sys.argv[2]), float(sys.argv[3]); step = float(sys.argv[4]) if len(sys.argv) > 4 else 0.1
w.setpos(int(a * rate)); raw = w.readframes(int((b - a) * rate))
n = len(raw) // (2 * ch); left = struct.unpack("<%dh" % (n * ch), raw[:n * 2 * ch])[0::ch]
def g(x, f):
    k = 2 * math.cos(2 * math.pi * f / rate); s1 = s2 = 0.0
    for v in x:
        s1, s2 = v + k * s1 - s2, s1
    return s1 * s1 + s2 * s2 - k * s1 * s2
m = int(step * rate); out = []
for i in range(0, n - m + 1, m):
    x = left[i:i + m]; e = sum(v * v for v in x)
    if e == 0:
        out.append("."); continue
    share = 2 * g(x, 1000) / (len(x) * e); rms = 20 * math.log10(math.sqrt(e / len(x)) / 32768)
    out.append("T" if share > 0.8 else ("t" if share > 0.4 else ("s" if rms > -45 else "_")))
print("%.1f-%.1f s, %.1f s per char (T: 1 kHz > 80 %%, t: > 40 %%, s: other sound, _: quiet, .: digital zero)" % (a, b, step))
print("".join(out))
