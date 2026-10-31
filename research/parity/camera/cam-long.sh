#!/bin/bash
# A long frame: FLL grown so that the exposure covers it, N frames kept.
S=/sys/kernel/debug/t715-cam/stage; D=/sys/kernel/debug/t715-capture; I="python3 /root/t715-cam-init.py /root/6b2_seq.txt"
EXP=${1:-0x7ff0}; GAIN=${2:-0x0080}; FLL=${3:-0x8000}; N=${4:-4}; W=${5:-2}
$I init >/dev/null
$I exp $EXP $GAIN $FLL | tail -1
$I on | tail -1
sleep $W
for i in $(seq 1 $N); do
  sleep $W
  head -c 4220480 $D/frame > /tmp/long$i.raw
done
$I off | tail -1
cat $D/status | tail -1 | cut -c1-90
python3 - $N <<'PY'
import array, sys
n = int(sys.argv[1])
s = None
for i in range(1, n + 1):
    a = array.array('H'); a.frombytes(open('/tmp/long%d.raw' % i, 'rb').read())
    if s is None:
        s = array.array('L', a)
    else:
        for j in range(len(a)):
            s[j] += a[j]
out = array.array('H', (min(65535, v // n) for v in s))
open('/tmp/avg.raw', 'wb').write(out.tobytes())
v = sorted(out[i] for i in range(0, len(out), 257)); m = len(v)
print('min', v[0], 'p1', v[m // 100], 'p50', v[m // 2], 'p99', v[m * 99 // 100], 'max', v[-1])
PY
