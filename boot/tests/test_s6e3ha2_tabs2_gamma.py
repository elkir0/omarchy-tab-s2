#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Host-side check of the S6E3HA2 (SM-T715) brightness / dynamic-AID port.

What is under test
------------------
The mainline panel driver keeps all of its brightness logic (tables,
MTP decode, the dynamic-AID gamma computation, AID / ELVSS / VINT / ACL
choices) in a self-contained header next to it:

    src/linux-6.12/drivers/gpu/drm/panel/
        panel-samsung-s6e3ha2-tabs2-dimming.h

The header only needs <linux/types.h>, <linux/math64.h> (div_s64,
div64_s64) and <linux/errno.h>.  This test writes three stub headers and
a small C harness into a temporary directory, compiles the harness
together with the *unmodified* kernel header, runs it, and compares
everything it prints against an independent Python re-implementation of
the stock code, whose tables are parsed at run time straight from
Samsung's GPL sources:

    src/kernel_universal5433/drivers/video/exynos/panels/
        dynamic_aid.c, dynamic_aid.h, dynamic_aid_s6e3ha2_tabs2.h,
        dynamic_aid_gamma_curve.h, s6e3ha2_tabs2_param.h,
        s6e3ha2_tabs2_mipi_lcd.c

So a transcription slip in the header (a table value, a loop bound, an
integer type) shows up as a mismatch, and so does a misreading in this
file.

Compiler: by default the gcc of the kbuild container (docker image
``t715-kbuild``, same one kernel/kbuild-mainline.sh uses), with
-Wall -Wextra -Werror and, when available, -fsanitize=undefined.  Set
S6E3HA2_TEST_CC (e.g. ``cc``) to compile on the host instead.

Paths can be overridden with S6E3HA2_STOCK_DIR and S6E3HA2_DIMMING_H.
The tests are skipped when the sources (sparse bundle mounted on
src/) or a compiler are missing.

Stdlib only.  Run: python3 boot/tests/test_s6e3ha2_tabs2_gamma.py -v
"""

import os
import random
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))

STOCK_DIR = os.environ.get(
    "S6E3HA2_STOCK_DIR",
    os.path.join(REPO_ROOT, "src", "kernel_universal5433", "drivers",
                 "video", "exynos", "panels"))
DIMMING_H = os.environ.get(
    "S6E3HA2_DIMMING_H",
    os.path.join(REPO_ROOT, "src", "linux-6.12", "drivers", "gpu",
                 "drm", "panel", "panel-samsung-s6e3ha2-tabs2-dimming.h"))
DOCKER_IMAGE = "t715-kbuild"

STOCK_FILES = ("dynamic_aid.c", "dynamic_aid.h",
               "dynamic_aid_s6e3ha2_tabs2.h", "dynamic_aid_gamma_curve.h",
               "s6e3ha2_tabs2_param.h", "s6e3ha2_tabs2_mipi_lcd.c")

# Error codes the header returns where stock has undefined behaviour
# (Linux and macOS agree on these two values).
ERANGE = 34
EDOM = 33

# Stock behaviour observed on this tablet: dumps/dmesg.txt, the
# "lcd panel:" lines of s6e3ha2_set_elvss() / update_brightness()
# (dev_info at s6e3ha2_tabs2_mipi_lcd.c:706-707 and :1115-1116).
# (brightness, bl, candela, caps, elvss level, union elvss_info value)
DMESG_POINTS = (
    (102, 49, 143, 1, 22, 0xb179c),  # dmesg.txt:75-76
    (62, 41, 87, 1, 19, 0xb199c),    # dmesg.txt:77-78
    (29, 27, 37, 0, 11, 0xb148c),    # dmesg.txt:79-80
    (20, 17, 20, 0, 4, 0xb118c),     # dmesg.txt:81-82
    (0, 0, 2, 0, 0, 0xb0d8c),        # dmesg.txt:158-159
    (95, 48, 134, 1, 21, 0xb189c),   # dmesg.txt:1789-1790
    (84, 46, 119, 1, 19, 0xb199c),   # dmesg.txt:2621-2622
)
# elvss_base (byte 22 of the 0xB6 command = 22nd byte read back) on that
# panel, as printed in the values above (bits 16..23).
DMESG_ELVSS_BASE = 0x0b
# "vint: 21", "acl: 2", "temperature: 25, tset: 25" (dmesg.txt:1751-1753)
DMESG_VINT = 0x21
DMESG_ACL = 0x02
DMESG_TSET = 25


class StockUndefined(Exception):
    """Stock would index out of bounds / divide by zero here."""

    def __init__(self, errno_value, what):
        super().__init__(what)
        self.errno_value = errno_value


# ---------------------------------------------------------------------------
# C integer semantics
# ---------------------------------------------------------------------------

def c_div(a, b):
    """C99 '/', div_s64() and div64_s64(): truncate towards zero."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def _wrap(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if x >> (bits - 1) else x


def i32(x):
    """Value as stored in a C int (gcc: modulo 2**32)."""
    return _wrap(x, 32)


def s64(x):
    return _wrap(x, 64)


def div_100(x):
    """DIV_100(x) = ((x + 50) / 100), dynamic_aid.c:56, on ints."""
    return c_div(i32(x + 50), 100)


# ---------------------------------------------------------------------------
# Stock source parser
# ---------------------------------------------------------------------------

def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


class StockSource:
    """Tables and constants parsed from the Samsung sources."""

    def __init__(self, directory):
        self.text = {}
        for name in STOCK_FILES:
            with open(os.path.join(directory, name), encoding="latin-1") as f:
                self.text[name] = _strip_comments(f.read())
        self.syms = {}
        for name in STOCK_FILES:
            for m in re.finditer(r"\benum\s*\{(.*?)\}\s*;", self.text[name],
                                 flags=re.S):
                members = [x.strip() for x in m.group(1).split(",")
                           if x.strip()]
                for i, member in enumerate(members):
                    self.syms[member] = i
        for name in STOCK_FILES:
            for m in re.finditer(r"^\s*#define\s+(\w+)\s+(-?(?:0[xX][0-9a-fA-F]+|\d+))\b",
                                 self.text[name], flags=re.M):
                self.syms.setdefault(m.group(1), int(m.group(2), 0))

    def define(self, name):
        return self.syms[name]

    def array(self, filename, name):
        text = self.text[filename]
        m = re.search(r"\b%s\s*\[[^\]]*\](?:\s*\[[^\]]*\])*\s*=\s*\{"
                      % re.escape(name), text)
        if not m:
            raise KeyError("%s not found in %s" % (name, filename))
        start = m.end() - 1
        depth = 0
        for end in range(start, len(text)):
            if text[end] == "{":
                depth += 1
            elif text[end] == "}":
                depth -= 1
                if depth == 0:
                    break
        tokens = re.findall(
            r"\.\.\.|[\[\]{},=]|-?0[xX][0-9a-fA-F]+|-?\d+|[A-Za-z_]\w*",
            text[start:end + 1])
        value, pos = self._parse(tokens, 0)
        assert pos == len(tokens)
        return value

    def pointer_alias(self, filename, name):
        m = re.search(r"\*\s*%s\s*=\s*(\w+)\s*;" % re.escape(name),
                      self.text[filename])
        return m.group(1)

    def _value(self, token):
        if re.match(r"-?(0[xX][0-9a-fA-F]+|\d+)$", token):
            return int(token, 0)
        return self.syms.get(token, token)

    def _parse(self, tokens, pos):
        if tokens[pos] != "{":
            return self._value(tokens[pos]), pos + 1
        pos += 1
        items = {}
        index = 0
        while tokens[pos] != "}":
            if tokens[pos] == "[":
                lo = self._value(tokens[pos + 1])
                if tokens[pos + 2] == "...":
                    hi = self._value(tokens[pos + 3])
                    pos += 4
                else:
                    hi = lo
                    pos += 2
                assert tokens[pos] == "]" and tokens[pos + 1] == "="
                item, pos = self._parse(tokens, pos + 2)
                for k in range(lo, hi + 1):
                    items[k] = item
                index = hi + 1
            else:
                items[index], pos = self._parse(tokens, pos)
                index += 1
            if tokens[pos] == ",":
                pos += 1
        size = max(items) + 1 if items else 0
        return [items.get(k) for k in range(size)], pos + 1


# ---------------------------------------------------------------------------
# Python port of the stock code
# ---------------------------------------------------------------------------

DAID = "dynamic_aid_s6e3ha2_tabs2.h"
CURVES = "dynamic_aid_gamma_curve.h"
PARAM = "s6e3ha2_tabs2_param.h"
LCD = "s6e3ha2_tabs2_mipi_lcd.c"
ALGO = "dynamic_aid.c"


class StockModel:
    def __init__(self, src):
        self.src = src
        s = src.define
        self.ci_max = s("CI_MAX")
        self.iv_max = s("IV_MAX")
        self.ibr_max = s("IBRIGHTNESS_MAX")

        # init_dynamic_aid(), lcd.c:777-795
        lcd = src.text[LCD]
        assert "lcd->daid.vreg = VREG_OUT_X1000;" in lcd
        assert "daid.vref_h" not in lcd       # never set -> kzalloc'd 0
        assert "d_aid.vreg = MUL_100(param.vreg);" in src.text[ALGO]
        self.vreg = s("VREG_OUT_X1000") * 100
        self.vref_h = 0
        self.iv_tbl = src.array(DAID, "index_voltage_table")[:self.iv_max]
        self.iv_top = self.iv_tbl[self.iv_max - 1]
        self.ibr_tbl = src.array(DAID, "index_brightness_table")
        self.ibr_top = self.ibr_tbl[self.ibr_max - 1]
        self.gamma_default = src.array(
            DAID, src.pointer_alias(DAID, "gamma_default"))
        self.formula = src.array(DAID, "gamma_formula")
        self.vt_voltage = src.array(DAID, "vt_voltage_value")
        self.br_base = src.array(DAID, "brightness_base_table")
        self.curves = {
            "gamma_curve_2p15_table": src.array(CURVES, "gamma_curve_2p15_table"),
            "gamma_curve_2p20_table": src.array(CURVES, "gamma_curve_2p20_table"),
        }
        self.gc_names = src.array(DAID, "gamma_curve_tables")
        self.gc_lut = self.curves[src.pointer_alias(DAID, "gamma_curve_lut")]
        self.offset_gra = src.array(DAID, "offset_gradation")
        self.offset_color = src.array(DAID, "offset_color")

        self.brightness_table = src.array(DAID, "brightness_table")
        self.inter_aor = src.array(DAID, "inter_aor_cmd")
        self.seq_gamma = src.array(PARAM, "SEQ_GAMMA_CONTROL_SET")
        self.seq_aid = src.array(PARAM, "SEQ_AID_SET")
        self.seq_elvss = src.array(PARAM, "SEQ_ELVSS_SET")
        self.seq_vint = src.array(PARAM, "SEQ_VINT_SET")
        self.mps = src.array(PARAM, "MPS_TABLE")
        self.elvss_dim = src.array(PARAM, "ELVSS_DIM_TABLE")
        self.elvss_table = src.array(PARAM, "ELVSS_TABLE")
        self.vint_dim = src.array(PARAM, "VINT_DIM_TABLE")
        self.vint_table = src.array(PARAM, "VINT_TABLE")
        self.acl_cutoff = [src.array(PARAM, n)
                           for n in src.array(PARAM, "ACL_CUTOFF_TABLE")]
        self.acl_opr = [src.array(PARAM, n)
                        for n in src.array(PARAM, "ACL_OPR_TABLE")]
        self.hbm = [src.array(PARAM, n) for n in src.array(PARAM, "HBM_TABLE")]

        self.mtp_len = s("LDI_MTP_LEN")
        self.elvss_len = len(self.seq_elvss) - 1   # LDI_ELVSS_LEN, lcd.c:70
        self.max_brightness = s("MAX_BRIGHTNESS")
        self.extend_brightness = s("EXTEND_BRIGHTNESS")
        self.default_brightness = s("DEFAULT_BRIGHTNESS")
        m = re.search(r"LEVEL_IS_CAPS_OFF\(level\)\s*\(level\s*<=\s*(\w+)\)",
                      lcd)
        self.caps_off_max = s(m.group(1))
        m = re.search(r"#define\s+DEFAULT_GAMMA_INDEX\s+(\w+)", lcd)
        self.default_gamma_index = s(m.group(1))

    # --- s6e3ha2_tabs2_mipi_lcd.c --------------------------------------------

    def init_mtp_data(self, raw):
        """init_mtp_data(), lcd.c:797-823 (works on a copy)."""
        d = list(raw)
        d[32] = d[34]
        d[31] = (d[33] >> 4) & 0xF
        d[30] = d[33] & 0xF
        n = self.iv_max * self.ci_max
        mtp = [0] * n
        j = 0
        for c in range(self.ci_max):
            neg = d[j] & 0x01
            j += 1
            mtp[(self.iv_max - 1) * self.ci_max + c] = -d[j] if neg else d[j]
            j += 1
        for i in range(self.iv_max - 2, -1, -1):
            for c in range(self.ci_max):
                if d[j] & 0x80:
                    mtp[self.ci_max * i + c] = -(d[j] & 0x7F)
                else:
                    mtp[self.ci_max * i + c] = d[j]
                j += 1
        return mtp

    def relocate(self, gamma):
        """init_gamma_table() "relocate gamma order", lcd.c:880, 896-914."""
        out = [0] * len(self.seq_gamma)
        out[0] = 0xCA
        ci = self.ci_max
        j = 1
        v = self.iv_max - 1
        for c in range(ci):
            g = gamma[v * ci + c]
            out[j] = 1 if g & 0x100 else 0
            out[j + 1] = g & 0xFF
            j += 2
        for v in range(self.iv_max - 2, -1, -1):
            for c in range(ci):
                out[j] = gamma[v * ci + c] & 0xFF
                j += 1
        return out

    def elvss_command(self, caps, level, elvss_read):
        """init_elvss_table(), lcd.c:959-990, one entry."""
        cmd = [0] * (self.elvss_len + 1)
        cmd[1:] = list(elvss_read)
        cmd[0] = 0xB6
        cmd[1] = self.mps[caps]
        cmd[2] = self.elvss_table[level]
        return cmd

    def decisions(self, brightness):
        """update_brightness() choices for one brightness (lcd.c:1087-1110)."""
        bl = self.brightness_table[brightness]
        if brightness == self.extend_brightness:      # LEVEL_IS_HBM
            bl = self.syms_ibr("IBRIGHTNESS_500NT")
        nit = self.ibr_tbl[bl]
        caps = 0 if bl <= self.caps_off_max else 1    # s6e3ha2_set_caps
        elvss = len(self.elvss_dim) - 1               # s6e3ha2_set_elvss
        for i, dim in enumerate(self.elvss_dim):
            if nit <= dim:
                elvss = i
                break
        vint = len(self.vint_dim) - 1                 # s6e3ha2_set_vint
        for i, dim in enumerate(self.vint_dim):
            if nit <= dim:
                vint = i
                break
        # s6e3ha2_set_acl with siop_enable = acl_enable = 0
        acl = 1
        if self.max_brightness <= brightness <= self.extend_brightness - 1:
            acl = 0
        return dict(bl=bl, nit=nit, aid=list(self.inter_aor[brightness]),
                    caps=caps, elvss=elvss, vint=vint, acl=acl)

    def syms_ibr(self, name):
        return self.src.define(name)

    # --- dynamic_aid.c ---------------------------------------------------------

    def dynamic_aid(self, mtp):
        """dynamic_aid() -> gamma[ibr][iv * CI_MAX + c] (dynamic_aid.c:424-503)."""
        ci, iv_max, ivt = self.ci_max, self.iv_max, self.iv_tbl
        vreg = i32(self.vreg)
        v0 = vreg
        vd = self.gamma_default

        # calc_point_voltages(), dynamic_aid.c:58-125
        pv = [[0] * ci for _ in range(iv_max)]
        den = self.formula[0][1]
        for c in range(ci):
            idx = vd[c] + mtp[c]
            if not 0 <= idx < len(self.vt_voltage):
                raise StockUndefined(ERANGE, "vt_voltage_value[%d]" % idx)
            t2 = s64(v0 * self.vt_voltage[idx])
            pv[0][c] = s64(v0 - c_div(t2, den))
        for iv in range(iv_max - 1, 0, -1):
            num, den = self.formula[iv]
            for c in range(ci):
                if iv == 1:
                    t1, t2 = v0, v0 - pv[iv + 1][c]
                elif iv == iv_max - 1:
                    t1, t2 = v0, v0 - self.vref_h
                else:
                    t1, t2 = pv[0][c], pv[0][c] - pv[iv + 1][c]
                t2 = s64(t2 * (vd[iv * ci + c] + mtp[iv * ci + c] + num))
                pv[iv][c] = s64(t1 - c_div(t2, den))

        # calc_output_voltages(), dynamic_aid.c:127-172 (struct rgb_t = int)
        ov = [[0] * ci for _ in range(self.iv_top + 1)]
        for iv in range(iv_max - 1, 0, -1):
            v_cnt = ivt[iv] - ivt[iv - 1]
            v_idx = ivt[iv]
            v = [i32(pv[iv][c]) for c in range(ci)]
            v_diff = [i32(pv[iv - 1][c] - pv[iv][c]) for c in range(ci)]
            if iv == 1:
                v_diff = [i32(vreg - pv[iv][c]) for c in range(ci)]
            for i in range(v_cnt):
                for c in range(ci):
                    ov[v_idx][c] = i32(v[c] + c_div(i32(v_diff[c] * i), v_cnt))
                v_idx -= 1
        for c in range(ci):
            ov[0][c] = vreg

        # init_l_lookup_table(), dynamic_aid.c:189-206
        lut = [div_100(i32(self.ibr_top * self.gc_lut[iv]))
               for iv in range(self.iv_top + 1)]

        gammas = []
        for ibr in range(self.ibr_max):
            gc = self.curves[self.gc_names[ibr]]
            base = self.br_base[ibr]
            # calc_l_values(), dynamic_aid.c:231-258
            l_value = [0] * iv_max
            for iv in range(iv_max - 1, -1, -1):
                if iv == iv_max - 1:
                    l_value[iv] = i32(base * 10000)
                else:
                    l_value[iv] = div_100(i32(base * gc[ivt[iv]]))
            # calc_m_gray_values(), dynamic_aid.c:260-289
            m_gray = [0] * iv_max
            for iv in range(iv_max - 1, -1, -1):
                m_gray[iv] = (self.min_diff_gray(l_value[iv], lut, self.iv_top)
                              + self.offset_gra[ibr][iv])
            # calc_m_rgb_voltages(), dynamic_aid.c:291-326
            mv = [[0] * ci for _ in range(iv_max)]
            for iv in range(iv_max - 1, 0, -1):
                if not 0 <= m_gray[iv] <= self.iv_top:
                    raise StockUndefined(ERANGE, "output_voltages[%d]" % m_gray[iv])
                mv[iv] = list(ov[m_gray[iv]])
            mv[0] = list(pv[0])
            # calc_gamma(), dynamic_aid.c:328-389
            res = [0] * (iv_max * ci)
            for iv in range(iv_max - 1, 0, -1):
                num, den = self.formula[iv]
                for c in range(ci):
                    if iv == 1:
                        t1, t2 = vreg - mv[iv][c], vreg - mv[iv + 1][c]
                    elif iv == iv_max - 1:
                        t1, t2 = vreg - mv[iv][c], vreg - self.vref_h
                    else:
                        t1, t2 = mv[0][c] - mv[iv][c], mv[0][c] - mv[iv + 1][c]
                    if t2 == 0:
                        raise StockUndefined(EDOM, "division by zero")
                    r = i32(s64(c_div(s64((t1 + 1) * den), t2) - num))
                    r = i32(r - mtp[iv * ci + c])
                    r = i32(r + self.offset_color[ibr][iv * ci + c])
                    r = 0 if r < 0 else r
                    if r > 255 and iv != iv_max - 1:
                        r = 255
                    res[iv * ci + c] = r
            for c in range(ci):
                res[c] = vd[c]
            gammas.append(res)
        return gammas

    @staticmethod
    def min_diff_gray(value, table, table_cnt):
        """min_diff_gray(), dynamic_aid.c:208-229."""
        ret = mn = table[table_cnt] + 1
        for i in range(table_cnt + 1):
            temp = abs(table[i] - value)
            if temp <= mn:
                mn = temp
                ret = i
            if i and table[i - 1] <= value <= table[i]:
                break
        return ret

    def gamma_commands(self, raw):
        """The 0xCA command of every level, or StockUndefined."""
        return [self.relocate(g)
                for g in self.dynamic_aid(self.init_mtp_data(raw))]


# ---------------------------------------------------------------------------
# C harness around the kernel header
# ---------------------------------------------------------------------------

STUB_TYPES = """\
#include <stdint.h>
typedef uint8_t u8;
typedef int8_t s8;
typedef uint32_t u32;
typedef int32_t s32;
typedef int64_t s64;
"""

# Same rounding as the kernel's div_s64() / div64_s64() (lib/math/div64.c):
# truncation towards zero, i.e. C99 '/'.
STUB_MATH64 = """\
static inline s64 div_s64(s64 dividend, s32 divisor)
{
	return dividend / divisor;
}

static inline s64 div64_s64(s64 dividend, s64 divisor)
{
	return dividend / divisor;
}
"""

# Linux values (include/uapi/asm-generic/errno-base.h); not <errno.h>,
# which on glibc includes <linux/errno.h> again, i.e. this stub.
STUB_ERRNO = """\
#define EDOM	33
#define ERANGE	34
"""

HARNESS_C = r"""
#include <stdio.h>
#include <string.h>
#include <linux/types.h>
#include "panel-samsung-s6e3ha2-tabs2-dimming.h"

static void pr_int(const char *tag, const int *v, int n)
{
	int i;

	printf("T %s", tag);
	for (i = 0; i < n; i++)
		printf(" %d", v[i]);
	printf("\n");
}

static void pr_s8(const char *tag, const s8 *v, int n)
{
	int i;

	printf("T %s", tag);
	for (i = 0; i < n; i++)
		printf(" %d", v[i]);
	printf("\n");
}

static void pr_u8(const char *tag, const u8 *v, int n)
{
	int i;

	printf("T %s", tag);
	for (i = 0; i < n; i++)
		printf(" %d", v[i]);
	printf("\n");
}

static void pr_bytes(const char *tag, int a, int b, const u8 *v, int n)
{
	int i;

	printf("%s %d %d", tag, a, b);
	for (i = 0; i < n; i++)
		printf(" %02x", v[i]);
	printf("\n");
}

static int parse_hex(const char *s, u8 *out, int n)
{
	int i;
	unsigned int x;

	for (i = 0; i < n; i++) {
		if (sscanf(s + 2 * i, "%2x", &x) != 1)
			return -1;
		out[i] = x;
	}
	return 0;
}

static struct tabs2_daid_work work;
static u8 table[TABS2_IBR_MAX][TABS2_GAMMA_PARAM_SIZE];

int main(void)
{
	char line[1024];
	u8 out[TABS2_GAMMA_PARAM_SIZE];
	u8 elvss[TABS2_ELVSS_PARAM_SIZE];
	u8 raw[TABS2_MTP_LEN];
	int mtp[TABS2_IV_MAX * TABS2_CI_MAX];
	int curve_sel[TABS2_IBR_MAX];
	int formula[TABS2_IV_MAX * 2];
	int i, b, ret, caps, level;

	printf("C IBR_MAX %d IV_MAX %d CI_MAX %d IV_TOP %d VREG %d VREF_H %d\n",
	       TABS2_IBR_MAX, TABS2_IV_MAX, TABS2_CI_MAX, TABS2_IV_TOP,
	       TABS2_VREG, TABS2_VREF_H);
	printf("C MTP_LEN %d ELVSS_LEN %d GAMMA_SIZE %d MAX %d DEFAULT %d EXTEND %d\n",
	       TABS2_MTP_LEN, TABS2_ELVSS_LEN, TABS2_GAMMA_PARAM_SIZE,
	       TABS2_MAX_BRIGHTNESS, TABS2_DEFAULT_BRIGHTNESS,
	       TABS2_EXTEND_BRIGHTNESS);
	printf("C CAPS_OFF_MAX %d IBR_162NT %d\n", TABS2_IBR_39NT, TABS2_IBR_162NT);

	pr_u8("brightness_table", tabs2_brightness_table, TABS2_MAX_BRIGHTNESS + 1);
	pr_int("index_brightness", tabs2_index_brightness, TABS2_IBR_MAX);
	pr_u8("inter_aor", &tabs2_inter_aor_cmd[0][0], 2 * (TABS2_MAX_BRIGHTNESS + 1));
	pr_u8("mps", tabs2_mps_table, TABS2_CAPS_MAX);
	pr_int("elvss_dim", tabs2_elvss_dim_table, TABS2_ELVSS_STATUS_MAX);
	pr_u8("elvss_table", tabs2_elvss_table, TABS2_ELVSS_STATUS_MAX);
	pr_int("vint_dim", tabs2_vint_dim_table, TABS2_VINT_STATUS_MAX);
	pr_u8("vint_table", tabs2_vint_table, TABS2_VINT_STATUS_MAX);
	pr_u8("acl_cutoff", &tabs2_acl_cutoff_table[0][0], 2 * TABS2_ACL_STATUS_MAX);
	pr_u8("acl_opr", &tabs2_acl_opr_table[0][0], 2 * TABS2_ACL_STATUS_MAX);
	pr_int("index_voltage", tabs2_index_voltage, TABS2_IV_MAX);
	pr_int("gamma_default", tabs2_gamma_default, TABS2_IV_MAX * TABS2_CI_MAX);
	for (i = 0; i < TABS2_IV_MAX; i++) {
		formula[2 * i] = tabs2_gamma_formula[i][0];
		formula[2 * i + 1] = tabs2_gamma_formula[i][1];
	}
	pr_int("gamma_formula", formula, 2 * TABS2_IV_MAX);
	pr_int("vt_voltage", tabs2_vt_voltage_value, TABS2_VT_VOLTAGE_COUNT);
	pr_int("brightness_base", tabs2_brightness_base, TABS2_IBR_MAX);
	pr_int("curve_2p15", tabs2_gamma_curve_2p15, TABS2_IV_TOP + 1);
	pr_int("curve_2p20", tabs2_gamma_curve_2p20, TABS2_IV_TOP + 1);
	for (i = 0; i < TABS2_IBR_MAX; i++)
		curve_sel[i] = tabs2_gamma_curve_tables[i] == tabs2_gamma_curve_2p15 ? 215 :
			       tabs2_gamma_curve_tables[i] == tabs2_gamma_curve_2p20 ? 220 : -1;
	pr_int("curve_sel", curve_sel, TABS2_IBR_MAX);
	printf("T curve_lut %d\n", tabs2_gamma_curve_lut == tabs2_gamma_curve_2p20 ? 220 : -1);
	pr_s8("offset_gradation", &tabs2_offset_gradation[0][0], TABS2_IBR_MAX * TABS2_IV_MAX);
	pr_s8("offset_color", &tabs2_offset_color[0][0],
	      TABS2_IBR_MAX * TABS2_IV_MAX * TABS2_CI_MAX);

	for (b = 0; b <= TABS2_MAX_BRIGHTNESS + 1; b++) {
		unsigned int bl = tabs2_brightness_to_level(b);

		printf("B %d %u %d %d %d %d %d %d %d\n", b, bl,
		       tabs2_index_brightness[bl],
		       tabs2_inter_aor_cmd[b > TABS2_MAX_BRIGHTNESS ? TABS2_MAX_BRIGHTNESS : b][0],
		       tabs2_inter_aor_cmd[b > TABS2_MAX_BRIGHTNESS ? TABS2_MAX_BRIGHTNESS : b][1],
		       tabs2_caps(bl), tabs2_elvss_level(bl), tabs2_vint_level(bl),
		       tabs2_acl_level(b));
	}

	tabs2_gamma_to_payload(tabs2_gamma_default, out);
	pr_bytes("D", 0, 0, out, TABS2_GAMMA_PARAM_SIZE);

	while (fgets(line, sizeof(line), stdin)) {
		if (line[0] == 'M' && line[1] == ' ') {
			if (parse_hex(line + 2, raw, TABS2_MTP_LEN))
				return 2;
			tabs2_decode_mtp(raw, mtp);
			printf("O");
			for (i = 0; i < TABS2_IV_MAX * TABS2_CI_MAX; i++)
				printf(" %d", mtp[i]);
			printf("\n");
			memset(&work, 0, sizeof(work));
			ret = tabs2_calc_gamma_table(raw, table, &work);
			printf("R %d\n", ret);
			if (!ret)
				for (i = 0; i < TABS2_IBR_MAX; i++)
					pr_bytes("G", i, 0, table[i], TABS2_GAMMA_PARAM_SIZE);
		} else if (line[0] == 'E' && line[1] == ' ') {
			if (parse_hex(line + 2, raw, TABS2_ELVSS_LEN))
				return 2;
			for (caps = 0; caps < TABS2_CAPS_MAX; caps++)
				for (level = 0; level < TABS2_ELVSS_STATUS_MAX; level++) {
					tabs2_build_elvss(elvss, caps, level, raw);
					pr_bytes("E", caps, level, elvss,
						 TABS2_ELVSS_PARAM_SIZE);
				}
		}
		printf("END\n");
		fflush(stdout);
	}

	return 0;
}
"""

CFLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
          "-Wno-unused-function"]
SANITIZE = ["-fsanitize=undefined", "-fno-sanitize-recover=all"]


def _docker_ok():
    if not shutil.which("docker"):
        return False
    try:
        r = subprocess.run(["docker", "image", "inspect", DOCKER_IMAGE],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def _toolchain():
    cc = os.environ.get("S6E3HA2_TEST_CC")
    if cc:
        return ("host", shlex.split(cc))
    if _docker_ok():
        return ("docker", ["gcc"])
    for name in ("gcc", "cc"):
        if shutil.which(name):
            return ("host", [name])
    return None


class Harness:
    """Builds the C harness once and runs it on a list of input lines."""

    def __init__(self, toolchain):
        self.kind, self.cc = toolchain
        self.tmp = tempfile.mkdtemp(prefix="s6e3ha2-gamma-")
        stub = os.path.join(self.tmp, "stub", "linux")
        os.makedirs(stub)
        for name, body in (("types.h", STUB_TYPES), ("math64.h", STUB_MATH64),
                           ("errno.h", STUB_ERRNO)):
            with open(os.path.join(stub, name), "w") as f:
                f.write(body)
        with open(os.path.join(self.tmp, "harness.c"), "w") as f:
            f.write(HARNESS_C)
        self.sanitized = True
        try:
            self._compile(CFLAGS + SANITIZE)
        except RuntimeError:
            self.sanitized = False
            self._compile(CFLAGS)

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _cmd(self, script):
        if self.kind == "docker":
            return ["docker", "run", "--rm", "-i", "--platform", "linux/arm64",
                    "-v", "%s:/w" % self.tmp,
                    "-v", "%s:/hdr:ro" % os.path.dirname(DIMMING_H),
                    "-w", "/w", DOCKER_IMAGE, "sh", "-c", script]
        return ["sh", "-c", script]

    def _paths(self):
        if self.kind == "docker":
            return "/w", "/hdr"
        return self.tmp, os.path.dirname(DIMMING_H)

    def _compile(self, flags):
        work, hdr = self._paths()
        script = "%s %s -I%s/stub -I%s -o %s/harness %s/harness.c" % (
            " ".join(shlex.quote(c) for c in self.cc),
            " ".join(flags), shlex.quote(work), shlex.quote(hdr),
            shlex.quote(work), shlex.quote(work))
        r = subprocess.run(self._cmd(script), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, timeout=600)
        if r.returncode:
            raise RuntimeError("harness build failed:\n" + r.stderr)

    def run(self, lines):
        work, _ = self._paths()
        r = subprocess.run(self._cmd("%s/harness" % shlex.quote(work)),
                           input="".join(l + "\n" for l in lines),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=600)
        if r.returncode:
            raise RuntimeError("harness failed (%d):\n%s" % (r.returncode,
                                                             r.stderr))
        return r.stdout


def parse_harness_output(text):
    """-> (consts, tables, per-brightness rows, default payload, blocks)."""
    consts, tables, rows, blocks = {}, {}, {}, []
    default = None
    block = []
    for line in text.splitlines():
        f = line.split()
        if f[0] == "C":
            for k, v in zip(f[1::2], f[2::2]):
                consts[k] = int(v)
        elif f[0] == "T":
            tables[f[1]] = [int(x) for x in f[2:]]
        elif f[0] == "B":
            v = [int(x) for x in f[1:]]
            rows[v[0]] = dict(bl=v[1], nit=v[2], aid=[v[3], v[4]], caps=v[5],
                              elvss=v[6], vint=v[7], acl=v[8])
        elif f[0] == "D":
            default = [int(x, 16) for x in f[3:]]
        elif f[0] == "END":
            blocks.append(block)
            block = []
        else:
            block.append(f)
    return consts, tables, rows, default, blocks


def parse_gamma_block(block):
    """One "M" block -> (mtp offsets, ret, {level: payload})."""
    offsets = [int(x) for x in block[0][1:]]
    assert block[0][0] == "O" and block[1][0] == "R"
    ret = int(block[1][1])
    gammas = {int(f[1]): [int(x, 16) for x in f[3:]]
              for f in block[2:] if f[0] == "G"}
    return offsets, ret, gammas


# ---------------------------------------------------------------------------
# Synthetic MTP inputs (raw 0xC8 read-backs, 44 bytes)
# ---------------------------------------------------------------------------

def mtp_vectors():
    vectors = []
    # 1. factory-perfect panel: all offsets 0, VT 0, date bytes only
    vectors.append(("zero", [0] * 40 + [0x51, 0x0C, 0x0E, 0x22]))
    # 2. hand-written plausible panel: small offsets of both signs
    v255 = [0x00, 0x05, 0x01, 0x03, 0x00, 0x0A]          # +5, -3, +10
    points = [0x02, 0x81, 0x03, 0x84, 0x00, 0x05, 0x01, 0x82, 0x06,
              0x83, 0x02, 0x00, 0x05, 0x86, 0x07, 0x88, 0x04, 0x01,
              0x0A, 0x8C, 0x0F, 0x90, 0x09, 0x03]         # V203 .. V3
    vectors.append(("plausible", v255 + points + [0, 0, 0] + [0x21, 0x03]
                    + [0] * 5 + [0x51, 0x0C, 0x0E, 0x22]))
    # 3. extremes, still inside the VT table: V255 -255/+255, points +-127
    vectors.append(("extreme_neg", [0x01, 0xFF] * 3 + [0xFF] * 24 + [0] * 3
                    + [0xFF, 0x0F] + [0] * 9))
    vectors.append(("extreme_pos", [0x00, 0xFF] * 3 + [0x7F] * 24 + [0] * 3
                    + [0x00, 0x00] + [0] * 9))
    # 4. VT blue outside vt_voltage_value[16]: stock reads out of bounds
    vectors.append(("vt_b_16", [0] * 34 + [0x10] + [0] * 9))
    vectors.append(("vt_b_neg", [0] * 34 + [0x81] + [0] * 9))
    rng = random.Random(0x5E3A2)
    # 5. realistic random panels: magnitudes up to 0x18, VT nibbles 0..7
    for k in range(12):
        raw = []
        for c in range(3):
            raw += [rng.randrange(2), rng.randrange(0x30)]
        for _ in range(24):
            raw.append(rng.randrange(0x18) | (0x80 if rng.randrange(2) else 0))
        raw += [rng.randrange(256) for _ in range(3)]  # overwritten by stock
        raw += [rng.randrange(8) | rng.randrange(8) << 4, rng.randrange(8)]
        raw += [rng.randrange(256) for _ in range(9)]
        vectors.append(("realistic_%d" % k, raw))
    # 6. arbitrary bytes, VT blue kept inside the table
    for k in range(12):
        raw = [rng.randrange(256) for _ in range(44)]
        raw[34] = rng.randrange(16)
        vectors.append(("random_%d" % k, raw))
    # 7. fully arbitrary bytes (mostly out-of-range VT blue)
    for k in range(4):
        vectors.append(("wild_%d" % k, [rng.randrange(256) for _ in range(44)]))
    for name, raw in vectors:
        assert len(raw) == 44, name
    return vectors


def elvss_vectors():
    rng = random.Random(0xB6)
    base = [0] * 22
    base[21] = DMESG_ELVSS_BASE
    return [("dmesg_base", base),
            ("random", [rng.randrange(256) for _ in range(22)])]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def _missing_sources():
    missing = [f for f in STOCK_FILES
               if not os.path.isfile(os.path.join(STOCK_DIR, f))]
    if not os.path.isfile(DIMMING_H):
        missing.append(DIMMING_H)
    return missing


class StockModelSelfTest(unittest.TestCase):
    """Checks of the Python port against the stock source's own values."""

    @classmethod
    def setUpClass(cls):
        missing = _missing_sources()
        if missing:
            raise unittest.SkipTest("sources not available (mount the "
                                    "sparse bundle on src/): %s"
                                    % ", ".join(missing))
        cls.m = StockModel(StockSource(STOCK_DIR))

    def test_table_shapes(self):
        m = self.m
        self.assertEqual(m.ibr_max, 66)
        self.assertEqual(m.iv_tbl, [0, 3, 11, 23, 35, 51, 87, 151, 203, 255])
        self.assertEqual(len(m.ibr_tbl), m.ibr_max)
        self.assertEqual(len(m.br_base), m.ibr_max)
        self.assertEqual(len(m.gc_names), m.ibr_max)
        self.assertEqual(len(m.offset_gra), m.ibr_max)
        self.assertEqual(len(m.offset_color), m.ibr_max)
        self.assertTrue(all(len(r) == m.iv_max for r in m.offset_gra))
        self.assertTrue(all(len(r) == m.iv_max * m.ci_max
                            for r in m.offset_color))
        self.assertEqual(len(m.brightness_table), m.extend_brightness + 1)
        self.assertEqual(len(m.inter_aor), m.extend_brightness + 1)
        self.assertEqual(len(m.seq_gamma), 36)
        self.assertEqual(len(m.seq_elvss), 23)
        self.assertEqual(m.mtp_len, 44)
        self.assertEqual(m.vreg, 680000)

    def test_gamma_curves_are_power_laws(self):
        # dynamic_aid_gamma_curve.h: value[i] = 1e6 * (i / 255) ** gamma
        for name, gamma in (("gamma_curve_2p15_table", 2.15),
                            ("gamma_curve_2p20_table", 2.20)):
            curve = self.m.curves[name]
            for i, value in enumerate(curve):
                self.assertLessEqual(abs(value - 1e6 * (i / 255) ** gamma), 1,
                                     "%s[%d]" % (name, i))

    def test_default_gamma_relocates_to_seq_gamma_control_set(self):
        # gamma_default_0[] laid out like init_gamma_table() gives back the
        # stock power-on template SEQ_GAMMA_CONTROL_SET (param.h:114-120)
        self.assertEqual(self.m.relocate(self.m.gamma_default),
                         self.m.seq_gamma)

    def test_zero_mtp_reference_level_is_default_gamma(self):
        # With no MTP offset, the top levels (gamma-2.20 curve = the lookup
        # curve, brightness base 360 = ibr_top, no offsets) must give back
        # the default register values.
        cmds = self.m.gamma_commands([0] * 44)
        self.assertEqual(cmds[self.m.src.define("IBRIGHTNESS_360NT")],
                         self.m.seq_gamma)
        self.assertEqual(cmds[self.m.src.define("IBRIGHTNESS_500NT")],
                         self.m.seq_gamma)

    def test_dmesg_brightness_points(self):
        for b, bl, nit, caps, level, value in DMESG_POINTS:
            d = self.m.decisions(b)
            self.assertEqual((d["bl"], d["nit"], d["caps"], d["elvss"]),
                             (bl, nit, caps, level), "brightness %d" % b)
            read = [0] * 22
            read[21] = DMESG_ELVSS_BASE
            cmd = self.m.elvss_command(caps, level, read)
            self.assertEqual(cmd[1] | cmd[2] << 8 | cmd[22] << 16, value)
            self.assertEqual(self.m.vint_table[d["vint"]], DMESG_VINT)
            self.assertEqual(self.m.acl_cutoff[d["acl"]][1], DMESG_ACL)

    def test_default_brightness(self):
        d = self.m.decisions(self.m.default_brightness)
        self.assertEqual((self.m.default_brightness, d["nit"]), (122, 172))


class HeaderVersusStockTest(unittest.TestCase):
    """The kernel header, compiled and run, against the stock model."""

    @classmethod
    def setUpClass(cls):
        missing = _missing_sources()
        if missing:
            raise unittest.SkipTest("sources not available (mount the "
                                    "sparse bundle on src/): %s"
                                    % ", ".join(missing))
        toolchain = _toolchain()
        if toolchain is None:
            raise unittest.SkipTest("no compiler (docker image %s or "
                                    "S6E3HA2_TEST_CC)" % DOCKER_IMAGE)
        cls.m = StockModel(StockSource(STOCK_DIR))
        cls.mtp = mtp_vectors()
        cls.elvss = elvss_vectors()
        harness = Harness(toolchain)
        try:
            lines = ["M " + bytes(raw).hex() for _, raw in cls.mtp]
            lines += ["E " + bytes(raw).hex() for _, raw in cls.elvss]
            out = harness.run(lines)
            cls.sanitized = harness.sanitized
        finally:
            harness.close()
        (cls.consts, cls.tables, cls.rows, cls.default,
         blocks) = parse_harness_output(out)
        cls.gamma_blocks = blocks[:len(cls.mtp)]
        cls.elvss_blocks = blocks[len(cls.mtp):]

    def test_constants(self):
        m, c = self.m, self.consts
        self.assertEqual(c["IBR_MAX"], m.ibr_max)
        self.assertEqual(c["IV_MAX"], m.iv_max)
        self.assertEqual(c["CI_MAX"], m.ci_max)
        self.assertEqual(c["IV_TOP"], m.iv_top)
        self.assertEqual(c["VREG"], m.vreg)
        self.assertEqual(c["VREF_H"], m.vref_h)
        self.assertEqual(c["MTP_LEN"], m.mtp_len)
        self.assertEqual(c["ELVSS_LEN"], m.elvss_len)
        self.assertEqual(c["GAMMA_SIZE"], len(m.seq_gamma))
        self.assertEqual(c["MAX"], m.max_brightness)
        self.assertEqual(c["DEFAULT"], m.default_brightness)
        self.assertEqual(c["EXTEND"], m.extend_brightness)
        self.assertEqual(c["CAPS_OFF_MAX"], m.caps_off_max)
        # DEFAULT_GAMMA_INDEX (lcd.c:58) seeds current_bl in the driver
        self.assertEqual(c["IBR_162NT"], m.default_gamma_index)

    def test_tables_match_stock(self):
        m, t = self.m, self.tables
        n = m.max_brightness + 1
        expect = {
            "brightness_table": m.brightness_table[:n],
            "index_brightness": m.ibr_tbl,
            "inter_aor": [x for pair in m.inter_aor[:n] for x in pair],
            "mps": m.mps,
            "elvss_dim": m.elvss_dim,
            "elvss_table": m.elvss_table,
            "vint_dim": m.vint_dim,
            "vint_table": m.vint_table,
            "acl_cutoff": [x for seq in m.acl_cutoff for x in seq],
            "acl_opr": [x for seq in m.acl_opr for x in seq],
            "index_voltage": m.iv_tbl,
            "gamma_default": m.gamma_default,
            "gamma_formula": [x for pair in m.formula for x in pair],
            "vt_voltage": m.vt_voltage,
            "brightness_base": m.br_base,
            "curve_2p15": m.curves["gamma_curve_2p15_table"],
            "curve_2p20": m.curves["gamma_curve_2p20_table"],
            "curve_sel": [{"gamma_curve_2p15_table": 215,
                           "gamma_curve_2p20_table": 220}.get(name, -1)
                          for name in m.gc_names],
            "curve_lut": [220 if m.gc_lut is m.curves["gamma_curve_2p20_table"]
                          else -1],
            "offset_gradation": [x for row in m.offset_gra for x in row],
            "offset_color": [x for row in m.offset_color for x in row],
        }
        self.assertEqual(sorted(expect), sorted(t))
        for name, values in expect.items():
            self.assertEqual(t[name], values, name)

    def test_per_brightness_decisions(self):
        for b in range(self.m.max_brightness + 1):
            self.assertEqual(self.rows[b], self.m.decisions(b),
                             "brightness %d" % b)
        # out-of-range input is clamped to 255, not read past the table
        row = dict(self.rows[self.m.max_brightness + 1])
        self.assertEqual(row["bl"], self.m.decisions(self.m.max_brightness)["bl"])

    def test_default_payload(self):
        self.assertEqual(self.default, self.m.seq_gamma)

    def test_gamma_tables(self):
        checked_ok = checked_err = 0
        for (name, raw), block in zip(self.mtp, self.gamma_blocks):
            offsets, ret, gammas = parse_gamma_block(block)
            self.assertEqual(offsets, self.m.init_mtp_data(raw), name)
            try:
                expect = self.m.gamma_commands(raw)
            except StockUndefined as e:
                self.assertEqual(ret, -e.errno_value, "%s: %s" % (name, e))
                self.assertEqual(gammas, {}, name)
                checked_err += 1
                continue
            self.assertEqual(ret, 0, name)
            self.assertEqual(sorted(gammas), list(range(self.m.ibr_max)), name)
            for level in range(self.m.ibr_max):
                self.assertEqual(gammas[level], expect[level],
                                 "%s level %d (%d nit)"
                                 % (name, level, self.m.ibr_tbl[level]))
            checked_ok += 1
        # the vector set must exercise both the normal and the guarded path
        self.assertGreaterEqual(checked_ok, 20)
        self.assertGreaterEqual(checked_err, 2)

    def test_vt_out_of_range_rejected(self):
        named = dict((name, block) for (name, _), block
                     in zip(self.mtp, self.gamma_blocks))
        for name in ("vt_b_16", "vt_b_neg"):
            self.assertEqual(parse_gamma_block(named[name])[1], -ERANGE, name)

    def test_elvss_commands(self):
        for (name, raw), block in zip(self.elvss, self.elvss_blocks):
            got = {(int(f[1]), int(f[2])): [int(x, 16) for x in f[3:]]
                   for f in block}
            self.assertEqual(len(got), 2 * len(self.m.elvss_dim), name)
            for (caps, level), cmd in got.items():
                self.assertEqual(cmd, self.m.elvss_command(caps, level, raw),
                                 "%s caps %d level %d" % (name, caps, level))

    def test_dmesg_points_through_header(self):
        block = self.elvss_blocks[0]           # "dmesg_base" vector
        cmds = {(int(f[1]), int(f[2])): [int(x, 16) for x in f[3:]]
                for f in block}
        for b, bl, nit, caps, level, value in DMESG_POINTS:
            row = self.rows[b]
            self.assertEqual((row["bl"], row["nit"], row["caps"],
                              row["elvss"]), (bl, nit, caps, level))
            cmd = cmds[(caps, level)]
            self.assertEqual(cmd[1] | cmd[2] << 8 | cmd[22] << 16, value)

    def test_harness_was_sanitized(self):
        if not self.sanitized:
            self.skipTest("compiler without -fsanitize=undefined")


def print_gamma_table(mtp_hex):
    """--mtp <88 hex digits>: the stock 0xCA table for a logged MTP read.

    Paste the bytes of the driver's "MTP (C8h, 44 bytes): .." boot line
    (spaces allowed) to get every level, for comparison with its
    "gamma <nit> nit (CAh): .." line.
    """
    raw = bytes.fromhex(mtp_hex.replace(" ", "").replace(":", ""))
    if len(raw) != 44:
        raise SystemExit("need 44 MTP bytes, got %d" % len(raw))
    m = StockModel(StockSource(STOCK_DIR))
    print("MTP offsets VT..V255:", m.init_mtp_data(raw))
    try:
        cmds = m.gamma_commands(raw)
    except StockUndefined as e:
        raise SystemExit("stock would hit undefined behaviour: %s" % e)
    for level, cmd in enumerate(cmds):
        print("%2d %3d nit: %s" % (level, m.ibr_tbl[level],
                                   " ".join("%02x" % x for x in cmd)))


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 3 and sys.argv[1] == "--mtp":
        print_gamma_table(" ".join(sys.argv[2:]))
    else:
        unittest.main()
