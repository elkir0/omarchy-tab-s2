#!/usr/bin/env bash
# Tests for tools/t715-isa-audit. Exits 0 only if every test passes (skipped
# tests, announced with SKIP, do not fail the run); the last line is "ALL PASS".
#
# Compiler fixtures need a clang that targets aarch64-linux-gnu (on the Mac:
# xcrun clang); without one they are skipped. The real binary
# tests/real-voxtype-onnx-lse.elf is git-ignored; its tests are skipped when
# it is absent.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$HERE/../../tools/t715-isa-audit"
REAL="$HERE/real-voxtype-onnx-lse.elf"
PY=${PYTHON:-python3}
T=$(mktemp -d "${TMPDIR:-/tmp}/t715-isa-audit-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

npass=0 nfail=0 nskip=0
pass() { npass=$((npass + 1)); echo "PASS  $1"; }
fail() { nfail=$((nfail + 1)); echo "FAIL  $1"; }
skip() { nskip=$((nskip + 1)); echo "SKIP  $1"; }

# expect NAME WANT_EXIT PY_EXPR TOOL_ARGS...
# Runs the tool with --json --faults 0 and evaluates PY_EXPR with:
#   d (document), files, s (summary), f (first file), v (its verdict),
#   c (its counts), lse (its lse split), by (files keyed by path suffix).
expect() {
    local name=$1 want=$2 expr=$3 rc
    shift 3
    "$PY" "$TOOL" --json --faults 0 "$@" >"$T/out.json" 2>"$T/err.txt"
    rc=$?
    if grep -q Traceback "$T/err.txt"; then
        fail "$name: traceback"; sed 's/^/      /' "$T/err.txt"; return
    fi
    if [ "$rc" != "$want" ]; then
        fail "$name: exit $rc, want $want"; head -c 2000 "$T/out.json"; return
    fi
    if "$PY" - "$expr" "$T/out.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[2]))
files, s = d["files"], d["summary"]
f = files[0] if files else {}
v, c, lse = f.get("verdict"), f.get("counts", {}), f.get("lse", {})
by = {}
for x in files:
    for k in range(len(x["path"])):
        by.setdefault(x["path"][k:], x)
sys.exit(0 if eval(sys.argv[1]) else 1)
EOF
    then pass "$name"
    else fail "$name: $expr"; head -c 3000 "$T/out.json"; echo
    fi
}

zero_except() {  # Python expression: every count is 0 except the named ones
    local keys="" k
    for k in "$@"; do keys="$keys'$k',"; done
    echo "all(n == 0 for k, n in c.items() if k not in ($keys))"
}

echo "== tool"
if "$PY" -m py_compile "$TOOL"; then pass "py_compile"; else fail "py_compile"; fi
"$PY" "$TOOL" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no PATH: exit 2" || fail "no PATH: exit $rc, want 2"
"$PY" "$TOOL" --bogus "$TOOL" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "unknown option: exit 2" || fail "unknown option: exit $rc, want 2"
"$PY" "$TOOL" "$T/does-not-exist" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "missing PATH: exit 2" || fail "missing PATH: exit $rc, want 2"

echo "== hand-written ELF fixtures"
H="$T/hand"
"$PY" "$HERE/mkelf.py" "$H" || fail "mkelf.py"
expect "helper named __aarch64_ldadd4_acq_rel in .symtab: outline, OK" 0 \
    'v == "OK" and lse == {"inline": 0, "outline_safe": 1, "outline_probable": 0} and c["lse"] == 1 and f["outline_mode"] == "symbols" and f["outline_helpers"] == ["__aarch64_ldadd4_acq_rel"]' \
    "$H/helper-symtab.o"
expect "LSE outside the helper's range: inline, RISK" 1 \
    'v == "RISK" and lse == {"inline": 1, "outline_safe": 1, "outline_probable": 0} and f["fault_count"] == 1 and f["faults"][0]["vaddr"] == "0x8" and f["faults"][0]["encoding"] == "0xb8e00020"' \
    "$H/helper-plus-inline.o"
expect "stripped libgcc-style helper: outline (probable), OK" 0 \
    'v == "OK" and lse == {"inline": 0, "outline_safe": 0, "outline_probable": 1} and f["outline_mode"] == "heuristic"' \
    "$H/helper-stripped.o"
expect "no section headers: PT_LOAD R+X decoded, RISK" 1 \
    'v == "RISK" and f["code_from"] == "segments" and lse["inline"] == 1 and f["executable"] and f["faults"][0]["vaddr"] == "0x400078" and f["faults"][0]["offset"] == "0x78" and f["faults"][0]["encoding"] == "0x38e883e9"' \
    "$H/static-lse"
expect "x86-64 ELF: skipped" 0 \
    'files == [] and s["skipped_other_arch"] == 1 and s["checked"] == 0' "$H/x86-64.o"
expect "truncated ELF (section headers cut): ERROR" 0 \
    'v == "ERROR" and "beyond end of file" in f["error"]' "$H/truncated.o"
expect "truncated ELF header: ERROR" 0 \
    'v == "ERROR" and "truncated" in f["error"]' "$H/truncated-header.o"
printf 'hello, not an ELF\n' >"$T/not-elf.txt"
: >"$T/empty"
expect "non-ELF and empty files: skipped" 0 \
    'files == [] and s["skipped_non_elf"] == 2' "$T/not-elf.txt" "$T/empty"

echo "== directory walk"
D="$T/tree"
mkdir -p "$D/bin" "$D/lib/sub"
cp "$H/static-lse" "$D/bin/"
cp "$H/helper-symtab.o" "$D/lib/sub/"
cp "$H/x86-64.o" "$D/lib/"
cp "$T/not-elf.txt" "$D/"
ln -s "$H/helper-plus-inline.o" "$D/lib/link-to-risk.o"
ln -s "$H" "$D/link-to-dir"
expect "directory walked, symlinks not followed" 1 \
    'len(files) == 2 and by["bin/static-lse"]["verdict"] == "RISK" and by["sub/helper-symtab.o"]["verdict"] == "OK" and s["skipped_other_arch"] == 1 and s["skipped_non_elf"] == 1 and not any("link-to" in x["path"] for x in files)' \
    "$D"

echo "== text output"
out=$("$PY" "$TOOL" "$H/helper-plus-inline.o" "$H/helper-symtab.o" 2>&1); rc=$?
first=$(printf '%s\n' "$out" | head -1)
case "$first" in
    "RISK  $H/helper-plus-inline.o  lse=1(inline)/1(outline)") pass "text line format" ;;
    *) fail "text line format: '$first'" ;;
esac
printf '%s\n' "$out" | grep -q '^      fault .text+0x8 0xb8e00020 lse$' && pass "text fault line" \
    || fail "text fault line: $out"
printf '%s\n' "$out" | tail -1 | grep -q '^summary: checked=2 ok=1 risk=1 error=0 skipped=0 ' \
    && pass "text summary line" || fail "text summary: $out"
[ "$rc" = 1 ] && pass "text mode exit 1 on RISK" || fail "text mode exit $rc, want 1"
"$PY" "$TOOL" "$H/helper-symtab.o" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && pass "exit 0 when all OK" || fail "exit $rc when all OK"

echo "== --run"
"$PY" "$TOOL" --json --run "$D" >"$T/run.json" 2>"$T/run.err"; rc=$?
if grep -q Traceback "$T/run.err"; then
    fail "--run: traceback"
elif "$PY" - "$T/run.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
runs = {x["path"].rsplit("/", 1)[-1]: x.get("run") for x in d["files"]}
assert runs["helper-symtab.o"] is None, "relocatable object must not be run"
r = runs["static-lse"]
assert r and r["arg"] in ("--version", "--help") and r["status"], r
cpu = ""
try:
    cpu = open("/proc/cpuinfo").read()
except OSError:
    pass
feats = " ".join(l.split(":", 1)[1] for l in cpu.splitlines() if l.lower().startswith("features")).split()
target = bool(feats) and "atomics" not in feats
if target:
    assert r["signal"] == "SIGILL" and d["summary"]["sigill"] == 1, r   # ARMv8.0: the SWPALB faults
else:
    assert d["warnings"], "warning expected off the target CPU"
print("      static-lse --run: %s%s" % (r["status"], "" if target else " (not the target CPU: %s)" % d["warnings"][0]))
EOF
then pass "--run: executables run, objects not, warning off-target"
else fail "--run"; head -c 2000 "$T/run.json"
fi
[ "$rc" = 1 ] && pass "--run exit 1" || fail "--run exit $rc, want 1"

echo "== compiler fixtures"
CC=()
if command -v xcrun >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1; then
    CC=(xcrun clang)
elif command -v clang >/dev/null 2>&1; then
    CC=(clang)
fi
HAVE_CC=0
if [ ${#CC[@]} -gt 0 ] && echo 'int x;' | "${CC[@]}" -target aarch64-linux-gnu -x c -c - -o "$T/probe.o" 2>/dev/null; then
    HAVE_CC=1
fi
C="$T/cc"
mkdir -p "$C"
cc() { "${CC[@]}" -target aarch64-linux-gnu -O2 -Wno-unused-command-line-argument "$@"; }

if [ "$HAVE_CC" = 0 ]; then
    skip "compiler fixtures: no clang that targets aarch64-linux-gnu (xcrun clang on the Mac)"
else
    cat >"$C/atomic.c" <<'EOF'
int bump(int *p) { return __atomic_fetch_add(p, 1, __ATOMIC_SEQ_CST); }
EOF
    cc -march=armv8.1-a -c "$C/atomic.c" -o "$C/atomic-v81.o"
    expect "__atomic_fetch_add, -march=armv8.1-a: inline LSE, RISK" 1 \
        "v == 'RISK' and lse['inline'] == 1 and lse['outline_safe'] + lse['outline_probable'] == 0 and $(zero_except lse)" \
        "$C/atomic-v81.o"
    cc -march=armv8-a -mno-outline-atomics -c "$C/atomic.c" -o "$C/atomic-llsc.o"
    expect "__atomic_fetch_add, -march=armv8-a -mno-outline-atomics: LL/SC, OK" 0 \
        "v == 'OK' and $(zero_except)" "$C/atomic-llsc.o"
    cc -march=armv8-a -moutline-atomics -c "$C/atomic.c" -o "$C/atomic-outline.o"
    expect "__atomic_fetch_add, -march=armv8-a -moutline-atomics: calls only, OK" 0 \
        "v == 'OK' and $(zero_except)" "$C/atomic-outline.o"

    cat >"$C/dot.c" <<'EOF'
#include <arm_neon.h>
int32x4_t dot(int32x4_t a, int8x16_t b, int8x16_t c) { return vdotq_s32(a, b, c); }
EOF
    if ! cc -ffreestanding -march=armv8.2-a+dotprod -c "$C/dot.c" -o "$C/dot.o" 2>/dev/null; then
        echo 'void dot(void) { __asm__ volatile("sdot v0.4s, v1.16b, v2.16b" ::: "v0"); }' >"$C/dot.c"
        cc -march=armv8.2-a+dotprod -c "$C/dot.c" -o "$C/dot.o"
    fi
    expect "-march=armv8.2-a+dotprod, vdotq_s32: RISK, dotprod" 1 \
        "v == 'RISK' and c['dotprod'] == 1 and $(zero_except dotprod)" "$C/dot.o"

    echo 'long acq(long *p) { long v; __asm__ volatile("ldapr %0, [%1]" : "=r"(v) : "r"(p) : "memory"); return v; }' >"$C/rcpc.c"
    cc -march=armv8.3-a -c "$C/rcpc.c" -o "$C/rcpc.o"
    expect "inline asm ldapr, -march=armv8.3-a: RISK, rcpc" 1 \
        "v == 'RISK' and c['rcpc'] == 1 and $(zero_except rcpc)" "$C/rcpc.o"

    echo 'void h(void) { __asm__ volatile("paciasp\n\tbti c\n\tautiasp"); }' >"$C/hint.c"
    cc -march=armv8.5-a -c "$C/hint.c" -o "$C/hint.o"
    expect "inline asm paciasp/bti c/autiasp: hint space, OK" 0 \
        "v == 'OK' and c['pac_bti'] == 3 and $(zero_except pac_bti)" "$C/hint.o"

    echo 'void p(void) { __asm__ volatile("pacia x0, x1\n\tldraa x0, [x1]\n\tretaa" ::: "x0"); }' >"$C/pauth.c"
    cc -march=armv8.3-a -c "$C/pauth.c" -o "$C/pauth.o"
    expect "inline asm pacia/ldraa/retaa: not hints, RISK pauth" 1 \
        "v == 'RISK' and c['pauth'] == 3 and $(zero_except pauth)" "$C/pauth.o"

    cat >"$C/half.c" <<'EOF'
_Float16 add(_Float16 a, _Float16 b) { return a + b; }
float widen(const _Float16 *p) { return (float)*p; }
void narrow(_Float16 *p, float x) { *p = (_Float16)x; }
EOF
    cc -march=armv8-a -c "$C/half.c" -o "$C/half-v80.o"
    expect "_Float16 at -march=armv8-a: FCVT to/from half only, OK" 0 \
        "v == 'OK' and $(zero_except)" "$C/half-v80.o"
    cc -march=armv8.2-a+fp16 -c "$C/half.c" -o "$C/half-fp16.o"
    expect "_Float16 at -march=armv8.2-a+fp16: fadd h, RISK fp16" 1 \
        "v == 'RISK' and c['fp16'] == 1 and $(zero_except fp16)" "$C/half-fp16.o"

    # each LSE class, one inline asm statement per object
    for insn in "cas x0, x1, [x2]" "casp x0, x1, x2, x3, [x4]" "ldadd x0, x1, [x2]" \
                "ldclral w0, w1, [x2]" "ldeorl x0, x1, [x2]" "ldsetah w0, w1, [x2]" \
                "ldsmaxb w0, w1, [x2]" "lduminal x0, x1, [x2]" "swpal x0, x1, [x2]" \
                "stadd w0, [x2]"; do
        op=${insn%% *}
        echo "void f(void) { __asm__ volatile(\"$insn\" ::: \"x0\", \"x1\", \"x2\", \"x3\", \"x4\", \"memory\"); }" >"$C/lse-$op.c"
        cc -march=armv8.1-a -c "$C/lse-$op.c" -o "$C/lse-$op.o"
        expect "inline asm $op: counted as LSE" 1 \
            "v == 'RISK' and c['lse'] == 1 and lse['inline'] == 1 and $(zero_except lse)" "$C/lse-$op.o"
    done

    # one instruction of every class, in table order
    cat >"$C/classes.s" <<'EOF'
.text
ldadd w0, w1, [x2]
sqrdmlah v0.4s, v1.4s, v2.4s
fadd h0, h1, h2
sdot v0.4s, v1.16b, v2.16b
ldapr x0, [x1]
fjcvtzs w0, d1
fcmla v0.4s, v1.4s, v2.4s, #90
retaa
frint32z s0, s1
bfdot v0.4s, v1.8h, v2.8h
smmla v0.4s, v1.16b, v2.16b
add z0.s, z1.s, z2.s
fmopa za0.s, p0/m, p1/m, z0.s, z1.s
eor3 v0.16b, v1.16b, v2.16b, v3.16b
cfinv
mrs x0, rndr
cpyfp [x0]!, [x1]!, x2!
abs x0, x1
paciasp
EOF
    if cc -march=armv9.4-a+sve2+sme+i8mm+bf16+rng+mops+cssc+sha3+sm4+fp16fml+rcpc+lse+rdm+dotprod+fp16+jscvt+fcma \
            -c "$C/classes.s" -o "$C/classes.o" 2>"$T/cc.err"; then
        expect "one instruction of each class: each counted once" 1 \
            "v == 'RISK' and all(n == 1 for n in c.values()) and len(c) == 19 and f['fault_count'] == 18" "$C/classes.o"
    else
        skip "all-classes object: this clang cannot assemble it ($(head -1 "$T/cc.err"))"
    fi

    # ARMv8.0 instructions that sit next to the extension encodings
    cat >"$C/v80.s" <<'EOF'
.text
ldr x0, [x1, x2]
ldr w0, [x1, w2, uxtw #2]
strb w0, [x1, x2]
ldur x0, [x1, #-8]
ldxr w0, [x1]
ldaxr x0, [x1]
stxr w2, w0, [x1]
stlxr w2, x0, [x1]
ldxp x0, x1, [x2]
stlxp w3, x0, x1, [x2]
ldar x0, [x1]
stlr w0, [x1]
ldarb w0, [x1]
fcvt s0, h1
fcvt h0, s1
fcvt d0, h1
fcvt h0, d1
fcvtn v0.4h, v1.4s
fcvtl v0.4s, v1.4h
fcvtl2 v0.4s, v1.8h
fadd s0, s1, s2
fmul d0, d1, d2
fmla v0.4s, v1.4s, v2.s[1]
fmul v0.2d, v1.2d, v2.d[1]
fmulx v0.4s, v1.4s, v2.s[0]
fmaxnmv s0, v1.4s
fmaxv s0, v1.4s
faddp s0, v1.2s
fmaxnmp d0, v1.2d
scvtf v0.4s, v1.4s, #3
fcvtzs v0.2d, v1.2d, #5
scvtf s0, w1
fcvtzs x0, d1
fmov s0, #1.0
fmov v0.4s, #1.0
fmov v0.2d, #-2.0
fmov x0, d1
fmov d0, x1
fmov x0, v1.d[1]
frintn s0, s1
frintx d0, d1
frinta v0.4s, v1.4s
fcmp s0, #0.0
fccmp d0, d1, #0, eq
fcsel s0, s1, s2, ne
fmadd d0, d1, d2, d3
fabd v0.4s, v1.4s, v2.4s
frecps v0.4s, v1.4s, v2.4s
frsqrts d0, d1, d2
facgt v0.4s, v1.4s, v2.4s
sqrdmulh v0.4s, v1.4s, v2.4s
sqrdmulh v0.8h, v1.8h, v2.h[3]
sqdmulh s0, s1, v2.s[1]
mla v0.4s, v1.4s, v2.s[1]
umull v0.2d, v1.2s, v2.s[1]
mul v0.4s, v1.4s, v2.4s
aese v0.16b, v1.16b
aesmc v0.16b, v1.16b
sha256h q0, q1, v2.4s
sha1c q0, s1, v2.4s
pmull v0.1q, v1.1d, v2.1d
pmull2 v0.8h, v1.16b, v2.16b
crc32cx w0, w1, x2
crc32b w0, w1, w2
nop
hint #0
yield
hint #20
dmb ish
isb
ret
br x16
blr x8
b .
add x0, x1, #1
adds x0, x1, #4095
adcs x0, x1, x2
adcs w0, w1, w2
csinv x0, x1, x2, eq
rbit x0, x1
clz x0, x1
cls w0, w1
rev x0, x1
udiv x0, x1, x2
lslv x0, x1, x2
mrs x0, tpidr_el0
msr tpidr_el0, x0
mrs x0, midr_el1
mrs x1, fpcr
msr daifset, #2
msr spsel, #1
adrp x16, .
ldrb w16, [x16, #0x574]
cbz w16, .
tbnz w8, #0, .
ext v0.16b, v1.16b, v2.16b, #3
dup v0.4s, w1
ins v0.s[1], w1
umov w0, v1.s[1]
tbl v0.16b, {v1.16b}, v2.16b
ld1 {v0.4s}, [x0]
st4 {v0.4s, v1.4s, v2.4s, v3.4s}, [x0], #64
ldp q0, q1, [x0]
stp x29, x30, [sp, #-16]!
ldpsw x0, x1, [x2]
prfm pldl1keep, [x0]
movi v0.2d, #0
mvni v0.4s, #1
bic v0.4s, #1
shl v0.4s, v1.4s, #3
ushr v0.2d, v1.2d, #63
sshll v0.8h, v1.8b, #0
uaddlv h0, v1.16b
addv s0, v1.4s
smaxv b0, v1.16b
addp d0, v1.2d
cnt v0.16b, v1.16b
udf #0
svc #0
brk #1
EOF
    if cc -march=armv8-a+crypto+crc -c "$C/v80.s" -o "$C/v80.o" 2>"$T/cc.err"; then
        expect "ARMv8.0 lookalikes (register-offset loads, LL/SC, FCVT half, fp/simd...): nothing counted" 0 \
            "v == 'OK' and $(zero_except) and f['words'] == 120" "$C/v80.o"
    else
        fail "ARMv8.0 lookalikes: assembler rejected the file: $(head -1 "$T/cc.err")"
    fi

    # data in .text: "$d" mapping symbols hide words that look like code
    printf '.text\nret\n.word 0x04a20020\n.word 0xb8200041\nret\n' >"$C/data.s"
    printf '.text\nret\n.inst 0x04a20020\n.inst 0xb8200041\nret\n' >"$C/inst.s"
    cc -c "$C/data.s" -o "$C/data.o" && cc -c "$C/inst.s" -o "$C/inst.o"
    expect "words under a \$d mapping symbol are data, not code" 0 \
        "v == 'OK' and $(zero_except)" "$C/data.o"
    expect "the same words as .inst are code: sve + lse" 1 \
        "v == 'RISK' and c['sve'] == 1 and c['lse'] == 1" "$C/inst.o"
fi

echo "== Arch packages"
P="$T/pkgroot"
mkdir -p "$P/usr/bin" "$P/usr/lib" "$P/usr/share/doc/fixture"
printf 'pkgname = fixture\npkgver = 1-1\narch = aarch64\n' >"$P/.PKGINFO"
cp "$H/static-lse" "$P/usr/bin/fixture"
cp "$H/helper-symtab.o" "$P/usr/lib/helper.o"
printf 'readme\n' >"$P/usr/share/doc/fixture/README"
zst="$T/fixture-1-1-aarch64.pkg.tar.zst"
if command -v bsdtar >/dev/null 2>&1 && bsdtar --zstd -cf "$zst" -C "$P" .PKGINFO usr 2>/dev/null; then
    made=bsdtar
elif command -v zstd >/dev/null 2>&1 && tar -cf - -C "$P" .PKGINFO usr | zstd -q -o "$zst"; then
    made="tar+zstd"
else
    made=""
fi
pkgexpr='len(files) == 2 and by["::usr/bin/fixture"]["verdict"] == "RISK" and by["::usr/lib/helper.o"]["verdict"] == "OK" and s["skipped_non_elf"] == 2'
if [ -n "$made" ]; then
    expect ".pkg.tar.zst (made with $made): extracted and walked" 1 "$pkgexpr" "$zst"
    "$PY" "$TOOL" "$zst" 2>&1 | grep -q "^RISK  $zst::usr/bin/fixture  " \
        && pass ".pkg.tar.zst: member shown as PKG::path" || fail ".pkg.tar.zst member path"
else
    skip ".pkg.tar.zst: neither bsdtar --zstd nor tar + zstd"
fi
gz="$T/fixture-1-1-aarch64.pkg.tar.gz"
if tar -czf "$gz" -C "$P" .PKGINFO usr; then
    expect ".pkg.tar.gz: extracted and walked" 1 "$pkgexpr" "$gz"
else
    fail ".pkg.tar.gz: tar -czf failed"
fi
printf 'not a tarball' >"$T/broken.pkg.tar.zst"
expect "unreadable package: ERROR, no traceback" 0 \
    'v == "ERROR" and "extract" in f["error"]' "$T/broken.pkg.tar.zst"
ls -d "${TMPDIR:-/tmp}"/t715-isa-audit-pkg-* >/dev/null 2>&1 \
    && fail "package temporary directories left behind" || pass "package temporary directories removed"

echo "== real binary"
if [ ! -f "$REAL" ]; then
    skip "real binary: $REAL is absent (git-ignored)"
else
    start=$("$PY" -c 'import time; print(time.time())')
    expect "real-voxtype-onnx-lse.elf: RISK, swpalb at 0xa5462c listed" 1 \
        'v == "RISK" and any(x["offset"] == "0xa5462c" and x["vaddr"] == "0xa5462c" and x["encoding"] == "0x38e88129" and x["class"] == "lse" for x in f["faults"]) and lse["inline"] > 0' \
        "$REAL"
    secs=$("$PY" -c "import time; print('%.1f' % (time.time() - $start))")
    words=$("$PY" -c 'import json,sys; f=json.load(open(sys.argv[1]))["files"][0]; print(f["words"], f["seconds"])' "$T/out.json")
    echo "      56 MB binary: ${words% *} words decoded in ${words#* } s; whole run ${secs} s"
    "$PY" -c "import sys; sys.exit(0 if float('$secs') < 60 else 1)" \
        && pass "real binary checked in under 60 s (${secs} s)" || fail "real binary took ${secs} s"
fi

echo "== $npass passed, $nfail failed, $nskip skipped"
if [ "$nfail" = 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "FAILED"
exit 1
