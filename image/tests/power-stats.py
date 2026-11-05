#!/usr/bin/env python3
"""Factorial statistics of a powerwin2.sh log.

usage: power-stats.py LOG [--skip S]   (a log of tests/ondevice/power-windows.sh)

Phase labels encode the factors as letter+digit pairs before an optional
"-N" repeat index, e.g. a0g1-2 (A57 offline, new GPU behaviour, 2nd run).
Window means (first S seconds of each phase dropped) are fitted with a
linear drift in time plus one effect per factor (level 1 minus level 0).
"""
import re
import sys
import statistics as st

args = sys.argv[1:]
log = args[0]
skip = float(args[args.index("--skip") + 1]) if "--skip" in args else 60.0

rows = []
for line in open(log):
    if line.startswith("#") or " ph=" not in line:
        continue
    f = line.split()
    d = {"up": float(f[0])}
    for kv in f[1:]:
        k, _, v = kv.partition("=")
        d[k] = v
    rows.append(d)

phases = []
for r in rows:
    if not phases or phases[-1][0] != r["ph"]:
        phases.append((r["ph"], []))
    phases[-1][1].append(r)

print(f"{'phase':8} {'n':>4} {'t_mid':>7} {'mA':>6} {'mV':>5} {'mW':>7} {'sem':>5} {'irq/s':>6} {'idle%':>6} {'tz':>12} {'cpus':>5}")
win = []
for name, rs in phases:
    t0 = rs[0]["up"]
    keep = [r for r in rs if r["up"] - t0 >= skip]
    if len(keep) < 5:
        continue
    ma = [-int(r["ma"]) for r in keep]
    mv = [int(r["mv"]) for r in keep]
    mw = [a * v / 1000 for a, v in zip(ma, mv)]
    dt = keep[-1]["up"] - keep[0]["up"]
    irq = (int(keep[-1]["intr"]) - int(keep[0]["intr"])) / dt if dt else 0
    busy = sum(int(keep[-1][k]) - int(keep[0][k]) for k in ("user", "sys"))
    idle = int(keep[-1]["idle"]) - int(keep[0]["idle"])
    idlep = 100 * idle / (idle + busy) if idle + busy else 0
    mid = keep[len(keep) // 2]
    tmid = (keep[0]["up"] + keep[-1]["up"]) / 2
    sem = st.stdev(mw) / len(mw) ** 0.5
    print(f"{name:8} {len(keep):4} {tmid:7.0f} {st.mean(ma):6.1f} {st.mean(mv):5.0f} {st.mean(mw):7.1f} {sem:5.1f} {irq:6.0f} {idlep:6.2f} {mid.get('tz', ''):>12} {mid.get('cpus', ''):>5}")
    win.append((name, tmid, st.mean(mw)))

def factors(name):
    base = name.split("-")[0]
    return dict((k, int(v)) for k, v in re.findall(r"([a-z])(\d)", base))

use = [w for w in win if factors(w[0]) and not w[0].startswith("settle")]
names = sorted({k for w in use for k in factors(w[0])})
if len(use) >= len(names) + 3:
    tm = sum(w[1] for w in use) / len(use)
    X = [[1.0, (w[1] - tm) / 60.0] + [float(factors(w[0]).get(k, 0)) for k in names] for w in use]
    y = [w[2] for w in use]
    n, m = len(X), len(X[0])
    A = [[sum(X[r][i] * X[r][j] for r in range(n)) for j in range(m)] for i in range(m)]
    inv = [[float(i == j) for j in range(m)] for i in range(m)]
    M = [row[:] for row in A]
    for c in range(m):
        piv = max(range(c, m), key=lambda r: abs(M[r][c]))
        M[c], M[piv] = M[piv], M[c]; inv[c], inv[piv] = inv[piv], inv[c]
        d = M[c][c]
        M[c] = [v / d for v in M[c]]; inv[c] = [v / d for v in inv[c]]
        for r in range(m):
            if r != c:
                f = M[r][c]
                M[r] = [a - f * b for a, b in zip(M[r], M[c])]
                inv[r] = [a - f * b for a, b in zip(inv[r], inv[c])]
    Xty = [sum(X[r][i] * y[r] for r in range(n)) for i in range(m)]
    coef = [sum(inv[i][j] * Xty[j] for j in range(m)) for i in range(m)]
    resid = [y[r] - sum(X[r][i] * coef[i] for i in range(m)) for r in range(n)]
    dof = n - m
    s2 = sum(e * e for e in resid) / dof if dof > 0 else float("nan")
    print(f"\nfit on {n} windows, dof {dof}: all factors at 0, mid-time: {coef[0]:.1f} mW, drift {coef[1]:+.2f} mW/min")
    for i, k in enumerate(names):
        print(f"  {k}=1 minus {k}=0: {coef[2 + i]:+.1f} mW (± {(s2 * inv[2 + i][2 + i]) ** 0.5:.1f})")
