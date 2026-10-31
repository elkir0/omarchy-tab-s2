#!/usr/bin/env python3
"""Validator for a UCM2 tree (generated or hand-written).

Validation levels, reported separately (never over-claim):

* Level 1 (default, pure stdlib): a small state machine per ``.conf``
  file -- balanced braces/quotes, known UCM keywords, ``cset`` argument
  shape, integer priorities, cross-file ``File``/``Include`` targets.
  ``Syntax`` is required in the card's top-level file
  (``conf.d/<card>/<card>.conf``) and accepted elsewhere only at the top
  level of a file (never inside a section): alsa-ucm-conf verb files
  normally carry no ``Syntax``.
* Level 1b (``--kernel DIR``, pure stdlib): every ``cset`` control name
  and value, and every ``PlaybackMixerElem``/``CaptureMixerElem``, must
  exist in the control set of the mainline kernel.  The control tables
  are extracted from the kernel sources (by default the WM8998 codec,
  the shared Arizona code and the gts28_wm1814 machine driver): controls,
  DAPM mux widgets, enum texts, integer ranges, byte counts.  alsa-lib
  aborts an ``EnableSequence`` at the first failing ``cset`` and clamps
  out-of-range integers silently, so both are reported as errors.
  ``--dump-controls`` prints the extracted table instead.
* Level 2 (``--docker``): every file of the card is loaded with
  ``snd_config_load()`` from the real alsa-lib inside a container.  The
  default image is ``debian:trixie`` (packages installed with apt at
  run time); ``--image`` can name a local image that already has alsa-lib
  and gcc (an Arch Linux ARM image, checked with pacman, needs no
  network).  The tree is copied into ``/usr/share/alsa/ucm2/`` first.
  This checks the full alsa-lib configuration grammar.

Level 3 (a full ``snd_use_case_mgr_open`` import through ``alsaucm``)
needs a kernel sound card and cannot pass in a plain container; when
``--docker`` is given and the image has ``alsaucm``, the attempt is run
anyway and its exact failure is reported as the evidence that level 3
was NOT achieved.

Usage::

    validate_ucm.py DIR [--card NAME] [--kernel KDIR] [--docker [--image IMG]]
    validate_ucm.py DIR --kernel KDIR --dump-controls

DIR is the directory that contains ``ucm2/`` (for the image overlay:
``image/rootfs/overlay/usr/share/alsa``).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

DOCKER_IMAGE = "debian:trixie"
DOCKER_PLATFORM = "linux/arm64"

KNOWN_SYNTAX = {1, 2, 3, 4, 5, 6, 7}

VALUE_KEYS_INT = {"PlaybackPriority", "CapturePriority", "PlaybackChannels",
                  "CaptureChannels"}
VALUE_KEYS_STR = {
    "TQ", "PlaybackPCM", "CapturePCM", "PlaybackVolume", "CaptureVolume",
    "PlaybackRate", "CaptureRate", "JackControl", "JackSwitch", "JackHWMutes",
    "EDIDFile", "CaptureCtl", "PlaybackCtl", "PlaybackChannelMap",
    "CaptureChannelMap", "PlaybackMixerElem", "CaptureMixerElem",
    "PlaybackMasterElem", "CaptureMasterElem", "PlaybackSwitch",
    "CaptureSwitch",
}
MIXER_ELEM_KEYS = {"PlaybackMixerElem", "CaptureMixerElem",
                   "PlaybackMasterElem", "CaptureMasterElem"}

CSET_RE = re.compile(r"^name='([^']+)' (\S.*)$")

# Section heads, possibly with a quoted suffix (SectionDevice."Speaker").
SECTION_RE = re.compile(
    r"^(Section(?:UseCase|Verb|Device|Modifier))(?:\.[^\s{}]+)?$")

ARRAY_KINDS = {
    "EnableSequence", "DisableSequence", "BootSequence",
    "FixedBootSequence", "ConflictingDevice", "SupportedDevices",
}

# conf.d/<card>/<card>.conf: the file alsa-lib opens for a card.
TOP_LEVEL_RE = re.compile(r"^conf\.d/([^/]+)/\1\.conf$")


def is_top_level(relpath):
    """True for the card's top-level file, relative to ucm2/."""
    return bool(TOP_LEVEL_RE.match(relpath.replace(os.sep, "/")))


class FileValidator(object):
    """Line-based UCM structural validator (level 1).

    Understands the alsa-ucm-conf layout style:

        SectionDevice."Speaker" {     <- statement opens a compound
        \tEnableSequence [           <- statement opens an array
        \t\tcset "name='X' 1"       <- array item
        \t]                            <- closes the array
        }                             <- closes the compound
    """

    SECTION_BASES = {"SectionUseCase", "SectionVerb", "SectionDevice",
                     "SectionModifier", "Value", "If", "Condition"}

    def __init__(self, path, ucm_root, require_syntax=False):
        self.path = path
        self.ucm_root = ucm_root
        self.require_syntax = require_syntax
        self.errors = []
        self.devices = set()
        self.file_targets = []
        self.cset_count = 0
        self.csets = []              # (lineno, name, value)
        self.mixer_elems = []        # (lineno, key, element)
        self.syntax_seen = False
        self.stack = []              # "pending-section" | "section" | "array"
        self.array_kinds = []        # parallel to the array frames
        self.conflicts = []          # ConflictingDevice items seen

    def error(self, lineno, msg):
        self.errors.append("%s:%d: %s" % (self.path, lineno, msg))

    # -- scanning helpers --------------------------------------------------

    @staticmethod
    def strip_comment(line):
        """Drop a trailing # comment that is not inside quotes."""
        out = []
        quoted = False
        for ch in line:
            if ch == '"':
                quoted = not quoted
            if ch == "#" and not quoted:
                break
            out.append(ch)
        return "".join(out).rstrip()

    def tokenize(self, stmt, lineno):
        """Split a statement into (text, was_quoted) tokens."""
        tokens = []
        i, n = 0, len(stmt)
        while i < n:
            while i < n and stmt[i] in " \t":
                i += 1
            if i >= n:
                break
            if stmt[i] == '"':
                j = stmt.find('"', i + 1)
                if j < 0:
                    self.error(lineno, "unterminated quoted string: %r" % stmt)
                    return []
                tokens.append((stmt[i + 1:j], True))
                i = j + 1
            else:
                j = i
                while j < n and stmt[j] not in " \t\"":
                    j += 1
                tokens.append((stmt[i:j], False))
                i = j
        return tokens

    # -- statement checking --------------------------------------------------

    def check_statement(self, stmt, lineno):
        """Validate one statement line (trailing brace/bracket stripped)."""
        tokens = self.tokenize(stmt, lineno)
        if not tokens:
            self.error(lineno, "empty statement")
            return
        head, quoted = tokens[0]
        if quoted:
            self.error(lineno, "statement starts with a quoted string: %r"
                       % stmt)
            return

        # Section heads carry a quoted suffix (SectionDevice."Speaker"),
        # which the tokenizer would split; match the raw statement first.
        m = re.match(r'^(Section(?:UseCase|Verb|Device|Modifier))'
                     r'\."([^"]+)"$', stmt)
        if m:
            if m.group(1) == "SectionDevice":
                self.devices.add(m.group(2))
            return
        if re.match(r'^(Section(?:UseCase|Verb|Device|Modifier))$', stmt):
            return

        if head == "Syntax":
            if len(tokens) != 2 or tokens[1][1] \
                    or not tokens[1][0].isdigit() \
                    or int(tokens[1][0]) not in KNOWN_SYNTAX:
                self.error(lineno, "bad Syntax statement: %r" % stmt)
            elif self.syntax_seen:
                self.error(lineno, "duplicate Syntax statement")
            if self.stack:
                self.error(lineno, "Syntax is only valid at the top level "
                                   "of a file, not inside a block")
            self.syntax_seen = True
            return

        base = head.split(".")[0]

        if base == "cset":
            if len(tokens) != 2 or not tokens[1][1]:
                self.error(lineno, "cset needs one quoted argument: %r"
                           % stmt)
            else:
                m = CSET_RE.match(tokens[1][0])
                if not m:
                    self.error(lineno, "bad cset argument %r" % tokens[1][0])
                else:
                    self.cset_count += 1
                    self.csets.append((lineno, m.group(1), m.group(2)))
            return

        if base == "Comment":
            if len(tokens) != 2 or not tokens[1][1]:
                self.error(lineno, "Comment needs a quoted string: %r" % stmt)
            return

        if base == "File" or re.match(r"^Include\.[^.]+\.File$", head):
            if len(tokens) != 2 or not tokens[1][1]:
                self.error(lineno, "%s needs a quoted path: %r" % (head, stmt))
            else:
                self.file_targets.append(tokens[1][0])
            return

        if SECTION_RE.match(head):
            if len(tokens) != 1:
                self.error(lineno, "section head with arguments: %r" % stmt)
            if base == "SectionDevice":
                m = re.match(r'^SectionDevice\."([^"]+)"$', head)
                if not m:
                    self.error(lineno, "SectionDevice without quoted name: %r"
                               % head)
                else:
                    self.devices.add(m.group(1))
            return

        if base in ARRAY_KINDS:
            if len(tokens) != 1:
                self.error(lineno, "%s must stand alone: %r" % (base, stmt))
            return

        if base in VALUE_KEYS_INT:
            if len(tokens) != 2 or tokens[1][1] \
                    or not tokens[1][0].isdigit():
                self.error(lineno, "%s needs an integer: %r" % (base, stmt))
            return
        if base in VALUE_KEYS_STR:
            if len(tokens) != 2 or not tokens[1][1]:
                self.error(lineno, "%s needs a quoted string: %r"
                           % (base, stmt))
            elif base in MIXER_ELEM_KEYS:
                self.mixer_elems.append((lineno, base, tokens[1][0]))
            return

        # Define / If / Condition internals and other alsa-lib statements:
        # accepted without further shape checking.
        return

    # -- main pass -------------------------------------------------------------

    def run(self):
        with open(self.path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()

        for lineno, raw in enumerate(lines, 1):
            line = self.strip_comment(raw.strip())
            if not line:
                continue

            if line == "{":
                if self.stack and self.stack[-1] == "pending-section":
                    self.stack[-1] = "section"
                else:
                    self.error(lineno, "'{' without a section statement")
                continue
            if line == "}":
                if self.stack and self.stack[-1] == "section":
                    self.stack.pop()
                else:
                    self.error(lineno, "'}' without an open section")
                continue
            if line == "[":
                self.error(lineno, "standalone '[' is not valid here")
                continue
            if line == "]":
                if self.stack and self.stack[-1] == "array":
                    self.stack.pop()
                    self.array_kinds.pop()
                else:
                    self.error(lineno, "']' without an open array")
                continue

            # Statement line with a trailing block opener: the inline
            # brace opens (and annihilates with) the section right away.
            if line.endswith("{"):
                self.check_statement(line[:-1].rstrip(), lineno)
                self.stack.append("section")
                continue
            if line.endswith("["):
                stmt = line[:-1].rstrip()
                self.check_statement(stmt, lineno)
                base = stmt.split(".")[0].split(" ")[0].strip('"')
                self.stack.append("array")
                self.array_kinds.append(base if base in ARRAY_KINDS
                                        else "generic")
                continue
            if line.endswith("}") or line.endswith("]"):
                self.error(lineno, "statement and block closer on one "
                                   "line: %r" % line)
                continue

            # Inside an array: items.
            if self.stack and self.stack[-1] == "array":
                kind = self.array_kinds[-1]
                if kind == "ConflictingDevice":
                    if line.startswith('"') and line.endswith('"'):
                        self.conflicts.append(line[1:-1])
                    else:
                        self.error(lineno, "ConflictingDevice items must be "
                                           "quoted: %r" % line)
                elif kind in ("EnableSequence", "DisableSequence",
                              "BootSequence", "FixedBootSequence"):
                    if line.startswith("cset "):
                        self.check_statement(line, lineno)
                    else:
                        self.error(lineno, "unexpected sequence item: %r"
                                   % line)
                else:
                    self.check_statement(line, lineno)
                continue

            # Plain statement (root or section context).
            self.check_statement(line, lineno)

        if self.stack:
            self.errors.append("%s: unclosed block(s): %s"
                               % (self.path, self.stack))
        if self.require_syntax and not self.syntax_seen:
            self.errors.append("%s: missing 'Syntax' statement (required in "
                               "the card's top-level file)" % self.path)
        return not self.errors

    def cross_check(self):
        """ConflictingDevice names must exist as SectionDevice in this file."""
        for name in self.conflicts:
            if name not in self.devices:
                self.errors.append(
                    "%s: ConflictingDevice references unknown device %r"
                    % (self.path, name))
        for target in self.file_targets:
            candidate = os.path.join(self.ucm_root, target.lstrip("/"))
            if not os.path.isfile(candidate):
                self.errors.append("%s: File/Include target not found: %s"
                                   % (self.path, target))


def card_closure(validators, ucm_root, card):
    """Files reachable from conf.d/<card>/<card>.conf through File/Include."""
    by_path = {os.path.normpath(fv.path): fv for fv in validators}
    start = os.path.normpath(os.path.join(ucm_root, "conf.d", card,
                                          card + ".conf"))
    if start not in by_path:
        return None
    seen, todo = set(), [start]
    while todo:
        path = todo.pop()
        if path in seen or path not in by_path:
            continue
        seen.add(path)
        for target in by_path[path].file_targets:
            todo.append(os.path.normpath(
                os.path.join(ucm_root, target.lstrip("/"))))
    return [fv for fv in validators if os.path.normpath(fv.path) in seen]


def validate_tree(root, card=None):
    """Level 1 over DIR/ucm2 (or one card). Returns (ok, messages, files)."""
    ucm_root = os.path.join(root, "ucm2")
    messages = []
    ok = True
    conf_files = []
    for dirpath, _dirs, names in os.walk(ucm_root):
        for name in names:
            if name.endswith(".conf"):
                conf_files.append(os.path.join(dirpath, name))
    conf_files.sort()

    validators = []
    for path in conf_files:
        rel = os.path.relpath(path, ucm_root)
        fv = FileValidator(path, ucm_root, require_syntax=is_top_level(rel))
        fv.run()
        fv.cross_check()
        validators.append(fv)

    if card:
        selected = card_closure(validators, ucm_root, card)
        if selected is None:
            return False, ["no conf.d/%s/%s.conf under %s"
                           % (card, card, ucm_root)], []
        validators = selected

    for fv in validators:
        rel = os.path.relpath(fv.path, root)
        if fv.errors:
            ok = False
            messages.extend(fv.errors)
        messages.append("%-58s csets=%-4d %s" % (
            rel, fv.cset_count, "FAIL" if fv.errors else "ok"))
    return ok, messages, validators


# --------------------------------------------------------------------------
# Level 1b: control names and values against the mainline kernel sources
# --------------------------------------------------------------------------

# Sources of the SM-T715 card "wm1814", relative to the kernel tree.
DEFAULT_SOURCES = (
    "sound/soc/codecs/arizona.h",
    "sound/soc/codecs/arizona.c",
    "sound/soc/codecs/wm8998.c",
    "sound/soc/samsung/gts28_wm1814.c",
)
DEFAULT_REG_BYTES = 2        # Arizona registers are 16 bits wide

TOK_RE = re.compile(r'''(?P<str>"(?:[^"\\\n]|\\.)*")
                      |(?P<chr>'(?:[^'\\\n]|\\.)*')
                      |(?P<ws>\s+)
                      |(?P<id>[A-Za-z_]\w*)
                      |(?P<num>\d[\w.]*)
                      |(?P<op>\#\#|->|<<|>>|.)''', re.S | re.X)

DEFINE_RE = re.compile(r'^[ \t]*#[ \t]*define[ \t]+(\w+)(\(([^)]*)\))?'
                       r'[ \t]*(.*)$', re.M)

ENUM_DECL_TEXTS = {           # decl macro -> index of the texts argument
    "SOC_ENUM_SINGLE_DECL": 3,
    "SOC_ENUM_DOUBLE_DECL": 4,
    "SOC_ENUM_SINGLE_EXT_DECL": 1,
    "SOC_ENUM_SINGLE_VIRT_DECL": 1,
    "SOC_VALUE_ENUM_SINGLE_DECL": 4,
    "SOC_VALUE_ENUM_DOUBLE_DECL": 5,
    "SOC_VALUE_ENUM_SINGLE_AUTODISABLE_DECL": 4,
}
ENUM_EXPR = {                 # enum initializer -> (items index, texts index)
    "SOC_ENUM_SINGLE": (2, 3),
    "SOC_ENUM_DOUBLE": (3, 4),
    "SOC_ENUM_SINGLE_EXT": (0, 1),
    "SOC_ENUM_SINGLE_VIRT": (0, 1),
    "SOC_VALUE_ENUM_SINGLE": (3, 4),
    "SOC_VALUE_ENUM_DOUBLE": (4, 5),
    "SOC_VALUE_ENUM_SINGLE_AUTODISABLE": (3, 4),
}
# kcontrol macro -> (min index or None, max index, channels)
INT_CTLS = {
    "SOC_SINGLE": (None, 3, 1),
    "SOC_SINGLE_TLV": (None, 3, 1),
    "SOC_SINGLE_EXT": (None, 3, 1),
    "SOC_SINGLE_EXT_TLV": (None, 3, 1),
    "SOC_DAPM_SINGLE": (None, 3, 1),
    "SOC_DAPM_SINGLE_TLV": (None, 3, 1),
    "SOC_SINGLE_RANGE": (3, 4, 1),
    "SOC_SINGLE_RANGE_TLV": (3, 4, 1),
    "SOC_DOUBLE": (None, 4, 2),
    "SOC_DOUBLE_TLV": (None, 4, 2),
    "SOC_DOUBLE_EXT": (None, 4, 2),
    "SOC_DOUBLE_R": (None, 4, 2),
    "SOC_DOUBLE_R_TLV": (None, 4, 2),
    "SOC_DOUBLE_R_EXT": (None, 4, 2),
    "SOC_DOUBLE_R_RANGE_TLV": (4, 5, 2),
}
ENUM_CTLS = {"SOC_ENUM", "SOC_ENUM_EXT", "SOC_DAPM_ENUM", "SOC_DAPM_ENUM_EXT",
             "SOC_VALUE_ENUM", "SOC_DAPM_VALUE_ENUM"}
BYTES_CTLS = {"SND_SOC_BYTES": 2, "SND_SOC_BYTES_MASK": 2}   # regs index
BOOL_VALUES = {"on", "off", "yes", "no", "up", "down", "toggle"}


class Ctl(object):
    """One ALSA control as the kernel registers it."""

    def __init__(self, name, kind, origin, count=1, lo=0, hi=None,
                 texts=None):
        self.name = name
        self.kind = kind          # bool | int | enum | bytes | unknown
        self.origin = origin
        self.count = count
        self.lo = lo
        self.hi = hi
        self.texts = texts or []

    def describe(self):
        if self.kind == "enum":
            return "enum[%s]" % "|".join(self.texts)
        if self.kind == "int":
            return "int x%d [%s..%s]" % (self.count, self.lo, self.hi)
        if self.kind == "bool":
            return "bool x%d" % self.count
        if self.kind == "bytes":
            return "bytes x%d" % self.count
        return "unknown"


class CSourceError(Exception):
    pass


def strip_c(text):
    """Remove comments and line continuations; keep strings intact."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(" " + "\n" * text.count("\n", i, j))
            i = j
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    return "".join(out).replace("\\\n", " ")


def tokens_of(text):
    return [(m.lastgroup, m.group()) for m in TOK_RE.finditer(text)]


def split_args(toks):
    """Split a token list (no outer parens) at depth-0 commas."""
    args, cur, depth = [], [], 0
    for kind, val in toks:
        if val in "([{" and kind == "op":
            depth += 1
        elif val in ")]}" and kind == "op":
            depth -= 1
        if kind == "op" and val == "," and depth == 0:
            args.append(cur)
            cur = []
            continue
        cur.append((kind, val))
    if cur or args:
        args.append(cur)
    return args


def match_close(toks, i):
    """Index of the bracket closing toks[i]."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    opener, closer = toks[i][1], pairs[toks[i][1]]
    depth = 0
    for j in range(i, len(toks)):
        kind, val = toks[j]
        if kind != "op":
            continue
        if val == opener:
            depth += 1
        elif val == closer:
            depth -= 1
            if depth == 0:
                return j
    raise CSourceError("unbalanced %s" % opener)


def nows(toks):
    return [t for t in toks if t[0] != "ws"]


class ControlTable(object):
    """Control set of a card, extracted from ASoC driver sources."""

    def __init__(self, reg_bytes=DEFAULT_REG_BYTES):
        self.reg_bytes = reg_bytes
        self.func_macros = {}     # name -> (params, body)
        self.int_defines = {}     # name -> body text
        self.strarrays = {}       # name -> [texts]
        self.enums = {}           # name -> texts | [texts, ...]
        self.kcontrols = {}       # name -> entry tokens | [entry tokens]
        self.widget_arrays = {}   # name -> [entry tokens]
        self.ctl_arrays = {}      # name -> [entry tokens]
        self.used_controls = []   # array names referenced by .controls
        self.used_widgets = []    # array names referenced by .dapm_widgets
        self.ctls = {}            # control name -> Ctl
        self.notes = []

    # -- loading -------------------------------------------------------------

    def load(self, paths):
        texts = []
        for path in paths:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = strip_c(fh.read())
            for m in DEFINE_RE.finditer(text):
                name, params, body = m.group(1), m.group(3), m.group(4)
                if m.group(2) is not None:
                    plist = [p.strip() for p in params.split(",") if p.strip()]
                    # Only the upper-case helper macros that build tables;
                    # variadic logging macros are left alone.
                    if name.isupper() and "..." not in plist:
                        self.func_macros[name] = (plist, body)
                else:
                    self.int_defines[name] = body.strip()
            texts.append((path, re.sub(r"^[ \t]*#.*$", "", text, flags=re.M)))
        for path, text in texts:
            toks = self.merge_strings(self.expand(tokens_of(text)))
            self.parse_decls(nows(toks), path)
        self.build()

    def expand(self, toks, depth=0):
        """Expand the function-like helper macros (repeatedly)."""
        if depth > 12:
            raise CSourceError("macro expansion too deep")
        out, i, changed = [], 0, False
        while i < len(toks):
            kind, val = toks[i]
            if kind == "id" and val in self.func_macros:
                j = i + 1
                while j < len(toks) and toks[j][0] == "ws":
                    j += 1
                if j < len(toks) and toks[j] == ("op", "("):
                    end = match_close(toks, j)
                    args = split_args(toks[j + 1:end])
                    params, body = self.func_macros[val]
                    if len(args) == 1 and not nows(args[0]) and not params:
                        args = []
                    if len(args) != len(params):
                        raise CSourceError("%s: %d args for %d params"
                                           % (val, len(args), len(params)))
                    out.extend(self.substitute(body, dict(zip(params, args))))
                    i = end + 1
                    changed = True
                    continue
            out.append(toks[i])
            i += 1
        return self.expand(out, depth + 1) if changed else out

    @staticmethod
    def substitute(body, mapping):
        res = []
        for kind, val in tokens_of(body):
            if kind == "id" and val in mapping:
                res.extend(t for t in mapping[val])
            else:
                res.append((kind, val))
        # Token pasting: drop the ## and the white space around it.
        out = []
        i = 0
        while i < len(res):
            if res[i] == ("op", "##"):
                while out and out[-1][0] == "ws":
                    out.pop()
                i += 1
                while i < len(res) and res[i][0] == "ws":
                    i += 1
                if out and i < len(res):
                    prev = out.pop()
                    out.append(("id", prev[1] + res[i][1]))
                    i += 1
                continue
            out.append(res[i])
            i += 1
        out.insert(0, ("ws", " "))
        out.append(("ws", " "))
        return out

    @staticmethod
    def merge_strings(toks):
        out = []
        for kind, val in toks:
            if kind == "str":
                k = len(out) - 1
                while k >= 0 and out[k][0] == "ws":
                    k -= 1
                if k >= 0 and out[k][0] == "str":
                    out[k] = ("str", out[k][1][:-1] + val[1:])
                    del out[k + 1:]
                    continue
            out.append((kind, val))
        return out

    def parse_decls(self, toks, path):
        """Walk top-level declarations; skip function bodies."""
        start, i = 0, 0
        while i < len(toks):
            kind, val = toks[i]
            if kind == "op" and val in "([":
                i = match_close(toks, i) + 1
                continue
            if kind == "op" and val == "{":
                end = match_close(toks, i)
                if i > 0 and toks[i - 1] == ("op", ")"):
                    start = i = end + 1        # function definition
                    continue
                i = end + 1
                continue
            if kind == "op" and val == ";":
                self.declaration(toks[start:i], path)
                start = i = i + 1
                continue
            i += 1

    def declaration(self, decl, path):
        if not decl:
            return
        eq = None
        depth = 0
        for k, (kind, val) in enumerate(decl):
            if kind == "op" and val in "([{":
                depth += 1
            elif kind == "op" and val in ")]}":
                depth -= 1
            elif kind == "op" and val == "=" and depth == 0:
                eq = k
                break
        if eq is None:
            for k, (kind, val) in enumerate(decl):
                if kind == "id" and val in ENUM_DECL_TEXTS \
                        and k + 1 < len(decl) and decl[k + 1] == ("op", "("):
                    end = match_close(decl, k + 1)
                    args = split_args(decl[k + 2:end])
                    name = args[0][0][1]
                    self.enums[name] = ("texts",
                                        args[ENUM_DECL_TEXTS[val]], None)
            return
        lhs, rhs = decl[:eq], decl[eq + 1:]
        is_array = False
        k = len(lhs) - 1
        if lhs[k] == ("op", "]"):
            depth = 0
            while k >= 0:
                if lhs[k] == ("op", "]"):
                    depth += 1
                elif lhs[k] == ("op", "["):
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            k -= 1
            is_array = True
        if k < 0 or lhs[k][0] != "id":
            return
        name = lhs[k][1]
        ctype = " ".join(v for _, v in lhs[:k])
        items = None
        if rhs and rhs[0] == ("op", "{"):
            items = [a for a in split_args(rhs[1:match_close(rhs, 0)]) if a]
        if "char" in ctype and is_array and items is not None:
            self.strarrays[name] = [eval_c_string(a[0][1]) for a in items
                                    if a and a[0][0] == "str"]
        elif "soc_enum" in ctype:
            self.enums[name] = [("expr", a, None) for a in items] \
                if items is not None else ("expr", rhs, None)
        elif "snd_kcontrol_new" in ctype:
            if items is not None and is_array:
                self.kcontrols[name] = items
                self.ctl_arrays[name] = items
            else:
                self.kcontrols[name] = rhs
        elif "snd_soc_dapm_widget" in ctype and items is not None:
            self.widget_arrays[name] = items
        elif ("snd_soc_component_driver" in ctype or "snd_soc_card" in ctype) \
                and items is not None:
            for item in items:
                if len(item) >= 4 and item[0] == ("op", ".") \
                        and item[2] == ("op", "=") and item[3][0] == "id":
                    if item[1][1] == "controls":
                        self.used_controls.append(item[3][1])
                    elif item[1][1] == "dapm_widgets":
                        self.used_widgets.append(item[3][1])

    # -- evaluation ------------------------------------------------------------

    def eval_int(self, toks, depth=0):
        if depth > 10:
            raise CSourceError("integer expression too deep")
        expr = []
        i = 0
        while i < len(toks):
            kind, val = toks[i]
            if kind == "id" and val == "ARRAY_SIZE":
                end = match_close(toks, i + 1)
                expr.append(str(len(self.texts_ref(toks[i + 2:end])[0])))
                i = end + 1
                continue
            if kind == "id":
                if val not in self.int_defines:
                    raise CSourceError("unknown integer %s" % val)
                expr.append("(%d)" % self.eval_int(
                    nows(tokens_of(self.int_defines[val])), depth + 1))
            elif kind == "num":
                expr.append(str(int(val.rstrip("uUlL"), 0)))
            elif kind == "op" and val in "+-*/()<<>>|&":
                expr.append("//" if val == "/" else val)
            else:
                raise CSourceError("bad integer token %r" % val)
            i += 1
        return int(eval("".join(expr), {"__builtins__": {}}, {}))

    def texts_ref(self, toks):
        """`name`, `name + N` or `&name[N]` -> (texts, offset)."""
        toks = nows(toks)
        if toks and toks[0] == ("op", "&"):
            name = toks[1][1]
            off = self.eval_int(toks[3:-1]) if len(toks) > 2 else 0
        else:
            name = toks[0][1]
            off = self.eval_int(toks[2:]) if len(toks) > 2 else 0
        if name not in self.strarrays:
            raise CSourceError("unknown text array %s" % name)
        return self.strarrays[name][off:], off

    def enum_texts(self, entry):
        kind, toks, _ = entry
        if kind == "texts":
            return self.texts_ref(toks)[0]
        toks = nows(toks)
        macro = toks[0][1]
        if macro not in ENUM_EXPR or toks[1] != ("op", "("):
            raise CSourceError("unsupported enum initializer %s" % macro)
        args = split_args(toks[2:match_close(toks, 1)])
        items_i, texts_i = ENUM_EXPR[macro]
        texts = self.texts_ref(args[texts_i])[0]
        return texts[:self.eval_int(nows(args[items_i]))]

    def enum_ref(self, toks):
        toks = nows(toks)
        name = toks[0][1]
        if name not in self.enums:
            raise CSourceError("unknown enum %s" % name)
        entry = self.enums[name]
        if isinstance(entry, list):
            entry = entry[self.eval_int(toks[2:-1])]
        return self.enum_texts(entry)

    def kcontrol_ref(self, toks):
        toks = nows(toks)
        if toks and toks[0] == ("op", "&"):
            toks = toks[1:]
        name = toks[0][1]
        entry = self.kcontrols.get(name)
        if entry is None:
            raise CSourceError("unknown kcontrol %s" % name)
        if len(toks) > 1:
            entry = entry[self.eval_int(toks[2:-1])]
        return nows(entry)

    # -- control building ------------------------------------------------------

    def add(self, ctl):
        if ctl.name in self.ctls:
            self.notes.append("duplicate control %r (%s and %s)"
                              % (ctl.name, self.ctls[ctl.name].origin,
                                 ctl.origin))
        self.ctls[ctl.name] = ctl

    def control_from_entry(self, entry, origin, name=None):
        entry = nows(entry)
        if not entry:
            return None
        if entry[0] == ("op", "{"):
            inner = split_args(entry[1:match_close(entry, 0)])
            for item in inner:
                if len(item) >= 4 and item[1] == ("id", "name") \
                        and item[3][0] == "str":
                    return Ctl(name or eval_c_string(item[3][1]), "unknown",
                               origin)
            return None
        macro = entry[0][1]
        if len(entry) < 2 or entry[1] != ("op", "("):
            return None
        args = [nows(a) for a in split_args(entry[2:match_close(entry, 1)])]
        cname = None
        if args and args[0] and args[0][0][0] == "str":
            cname = eval_c_string(args[0][0][1])
        if macro == "SOC_DAPM_PIN_SWITCH":
            return Ctl(cname + " Switch", "bool", origin)
        cname = name or cname
        if cname is None:
            return None
        if macro in ENUM_CTLS:
            return Ctl(cname, "enum", origin, texts=self.enum_ref(args[1]))
        if macro in BYTES_CTLS:
            regs = self.eval_int(args[BYTES_CTLS[macro]])
            return Ctl(cname, "bytes", origin, count=regs * self.reg_bytes)
        if macro == "SOC_SINGLE_BOOL_EXT":
            return Ctl(cname, "bool", origin)
        if macro in INT_CTLS:
            lo_i, hi_i, chans = INT_CTLS[macro]
            hi = self.eval_int(args[hi_i])
            lo = self.eval_int(args[lo_i]) if lo_i is not None else 0
            span = hi - lo
            # snd_soc_info_volsw(): max 1 is a boolean unless the name
            # ends in " Volume"; the range variants are always integers.
            if lo_i is None and span == 1 and not cname.endswith(" Volume"):
                return Ctl(cname, "bool", origin, count=chans)
            return Ctl(cname, "int", origin, count=chans, lo=0, hi=span)
        return Ctl(cname, "unknown", origin)

    def build(self):
        for arr in self.used_controls:
            for entry in self.ctl_arrays.get(arr, []):
                try:
                    ctl = self.control_from_entry(entry, arr)
                except (CSourceError, IndexError, ValueError) as exc:
                    self.notes.append("%s: entry not understood (%s)"
                                      % (arr, exc))
                    continue
                if ctl:
                    self.add(ctl)
        for arr in self.used_widgets:
            for entry in self.widget_arrays.get(arr, []):
                entry = nows(entry)
                if len(entry) < 2 or entry[1] != ("op", "("):
                    continue
                macro = entry[0][1]
                args = [nows(a) for a in
                        split_args(entry[2:match_close(entry, 1)])]
                try:
                    if macro in ("SND_SOC_DAPM_MUX", "SND_SOC_DAPM_DEMUX"):
                        wname = eval_c_string(args[0][0][1])
                        ctl = self.control_from_entry(
                            self.kcontrol_ref(args[4]), arr, name=wname)
                        if ctl:
                            self.add(ctl)
                    elif macro in ("SND_SOC_DAPM_SWITCH",
                                   "SND_SOC_DAPM_MIXER",
                                   "SND_SOC_DAPM_MIXER_NAMED_CTL"):
                        wname = eval_c_string(args[0][0][1])
                        kc_args = args[4:5] if macro == "SND_SOC_DAPM_SWITCH" \
                            else args[4:5]
                        if not kc_args or kc_args[0] == [("id", "NULL")]:
                            continue
                        self.notes.append("%s: %s %r controls not expanded"
                                          % (arr, macro, wname))
                except (CSourceError, IndexError, ValueError) as exc:
                    self.notes.append("%s: widget not understood (%s)"
                                      % (arr, exc))

    # -- checking --------------------------------------------------------------

    def check_value(self, ctl, value):
        """Return an error string, or None when alsa-lib sets what is meant."""
        parts = value.split(",") if "," in value else [value]
        if len(parts) > max(ctl.count, 1):
            return "%d values for a %d-value control" % (len(parts), ctl.count)
        for part in parts:
            if part != part.strip():
                return "white space around %r (alsa-lib parses it as the " \
                       "minimum)" % part
            if ctl.kind == "enum":
                if part in ctl.texts:
                    continue
                if part.isdigit() and int(part) < len(ctl.texts):
                    continue
                return "%r is not an item of [%s]" % (
                    part, "|".join(ctl.texts))
            if ctl.kind == "bool":
                if part.lower() in BOOL_VALUES or part.isdigit():
                    continue
                return "%r is not a boolean value alsa-lib understands " \
                       "(on/off/yes/no/0/1)" % part
            if ctl.kind == "int":
                m = re.match(r"^(-?(?:0x[0-9a-fA-F]+|\d+))(%?)$", part)
                if not m:
                    return "%r is not an integer" % part
                num = int(m.group(1), 0)
                if m.group(2):
                    if not 0 <= num <= 100:
                        return "%r is not a percentage" % part
                elif not ctl.lo <= num <= ctl.hi:
                    return "%d outside [%d..%d] (alsa-lib clamps it)" % (
                        num, ctl.lo, ctl.hi)
                continue
            if ctl.kind == "bytes":
                if not re.match(r"^(0x[0-9a-fA-F]+|\d+)$", part) \
                        or not 0 <= int(part, 0) <= 255:
                    return "%r is not a byte" % part
                continue
        return None

    def check_validators(self, validators, root):
        """Level 1b over the csets and mixer elements. Returns (ok, msgs)."""
        msgs, ok, used = [], True, {}
        for fv in validators:
            rel = os.path.relpath(fv.path, root)
            for lineno, name, value in fv.csets:
                ctl = self.ctls.get(name)
                if ctl is None:
                    ok = False
                    msgs.append("%s:%d: control %r does not exist in the "
                                "mainline driver" % (rel, lineno, name))
                    continue
                used.setdefault(name, set()).add(value)
                if ctl.kind == "unknown":
                    msgs.append("%s:%d: note: value of %r not checked "
                                "(control type not understood)"
                                % (rel, lineno, name))
                    continue
                err = self.check_value(ctl, value)
                if err:
                    ok = False
                    msgs.append("%s:%d: %s = %r: %s" % (rel, lineno, name,
                                                         value, err))
            for lineno, key, elem in fv.mixer_elems:
                suffixes = (" Volume", " Switch", " Playback Volume",
                            " Playback Switch", " Capture Volume",
                            " Capture Switch")
                if not any(elem + s in self.ctls for s in suffixes):
                    ok = False
                    msgs.append("%s:%d: %s %r matches no '<elem> Volume' or "
                                "'<elem> Switch' control" % (rel, lineno, key,
                                                             elem))
        for name in sorted(used):
            msgs.append("  %-32s %-12s <- %s" % (
                name, self.ctls[name].kind, ", ".join(sorted(used[name]))))
        return ok, msgs


def eval_c_string(lit):
    """Decode a C string literal token (simple escapes only)."""
    body = lit[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(
        m.group(1), m.group(1)), body)


def load_controls(kernel, sources, reg_bytes):
    table = ControlTable(reg_bytes)
    table.load([os.path.join(kernel, s) for s in sources])
    return table


# --------------------------------------------------------------------------
# Level 2 / 3 inside Docker
# --------------------------------------------------------------------------

LOADER_C = r"""
#include <alsa/asoundlib.h>
int main(int argc, char **argv) {
    int i, bad = 0;
    for (i = 1; i < argc; i++) {
        snd_config_t *top = NULL;
        snd_input_t *in = NULL;
        int err;
        if (snd_config_top(&top) < 0) {
            fprintf(stderr, "%s: snd_config_top failed\n", argv[i]);
            bad = 1;
            continue;
        }
        err = snd_input_stdio_open(&in, argv[i], "r");
        if (err < 0) {
            fprintf(stderr, "%s: open: %s\n", argv[i], snd_strerror(err));
            snd_config_delete(top);
            bad = 1;
            continue;
        }
        err = snd_config_load(top, in);
        snd_input_close(in);
        if (err < 0) {
            fprintf(stderr, "%s: snd_config_load: %s\n", argv[i],
                    snd_strerror(err));
            snd_config_delete(top);
            bad = 1;
            continue;
        }
        snd_config_delete(top);
        printf("load OK: %s\n", argv[i]);
    }
    return bad;
}
"""


def docker_validate(root, files, card, image):
    """Levels 2 and 3 in a container. Returns the run result."""
    root = os.path.abspath(root)
    ucm_root = os.path.join(root, "ucm2")
    rels = sorted(os.path.relpath(f, ucm_root) for f in files)
    with tempfile.TemporaryDirectory(prefix="ucm-validate-") as tmp:
        # Ship the tree and the loader into an isolated directory.
        shutil.copytree(ucm_root, os.path.join(tmp, "ucm2"))
        with open(os.path.join(tmp, "loader.c"), "w") as fh:
            fh.write(LOADER_C)
        with open(os.path.join(tmp, "files.txt"), "w") as fh:
            fh.write("\n".join(rels) + "\n")
        script = r"""
set -e
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq alsa-utils alsa-ucm-conf libasound2-dev gcc >/dev/null
    echo "== alsa-lib / alsa-ucm-conf versions =="
    dpkg-query -W 'libasound2*' alsa-ucm-conf alsa-utils || true
elif command -v pacman >/dev/null 2>&1; then
    echo "== alsa-lib / alsa-ucm-conf versions (image packages, no install) =="
    pacman -Q alsa-lib gcc
    pacman -Q alsa-ucm-conf alsa-utils 2>/dev/null || true
else
    echo "image has neither apt-get nor pacman" >&2
    exit 3
fi
echo "== tree copied into /usr/share/alsa/ucm2/ =="
mkdir -p /usr/share/alsa/ucm2
cp -r /check/ucm2/. /usr/share/alsa/ucm2/
sed 's|^|/usr/share/alsa/ucm2/|' /check/files.txt
echo "== level 2: snd_config_load of every file of the card =="
gcc -o /tmp/loader /check/loader.c -lasound
/tmp/loader $(sed 's|^|/usr/share/alsa/ucm2/|' /check/files.txt)
echo "== level 3 attempt: alsaucm without a sound card =="
if command -v alsaucm >/dev/null 2>&1; then
    ( alsaucm -c "$CARD" list _verbs ) 2>&1 || echo "alsaucm rc=$? (expected: no kernel card in a plain container)"
else
    echo "alsaucm not in the image: level 3 not attempted"
fi
"""
        cmd = ["docker", "run", "--rm", "--platform", DOCKER_PLATFORM,
               "-e", "CARD=%s" % (card or ""),
               "-v", "%s:/check:ro" % tmp, image, "sh", "-c", script]
        return subprocess.run(cmd, capture_output=True, text=True)


def guess_card(root):
    confd = os.path.join(root, "ucm2", "conf.d")
    if os.path.isdir(confd):
        cards = sorted(d for d in os.listdir(confd)
                       if os.path.isdir(os.path.join(confd, d)))
        if len(cards) == 1:
            return cards[0]
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dir", help="tree that contains ucm2/")
    parser.add_argument("--card", help="validate only conf.d/CARD/CARD.conf "
                                       "and the files it pulls in")
    parser.add_argument("--kernel", default=os.environ.get("T715_KERNEL_DIR"),
                        help="kernel tree for level 1b (default: "
                             "$T715_KERNEL_DIR)")
    parser.add_argument("--sources", default=",".join(DEFAULT_SOURCES),
                        help="comma-separated driver sources, relative to "
                             "--kernel (default: the wm1814 card)")
    parser.add_argument("--reg-bytes", type=int, default=DEFAULT_REG_BYTES,
                        help="register width in bytes, for byte controls")
    parser.add_argument("--dump-controls", action="store_true",
                        help="print the control table extracted from "
                             "--kernel and exit")
    parser.add_argument("--docker", action="store_true",
                        help="also run level 2 (alsa-lib load) in Docker")
    parser.add_argument("--image", default=DOCKER_IMAGE,
                        help="Docker image for level 2 (default %s)"
                             % DOCKER_IMAGE)
    args = parser.parse_args(argv)

    sources = [s for s in args.sources.split(",") if s]
    if args.dump_controls:
        if not args.kernel:
            parser.exit(2, "validate_ucm: --dump-controls needs --kernel\n")
        table = load_controls(args.kernel, sources, args.reg_bytes)
        for name in sorted(table.ctls):
            ctl = table.ctls[name]
            print("%s\t%s\t%s" % (name, ctl.describe(), ctl.origin))
        for note in table.notes:
            print("# note: %s" % note, file=sys.stderr)
        return 0

    if not os.path.isdir(os.path.join(args.dir, "ucm2")):
        parser.exit(2, "validate_ucm: %s does not look like a UCM tree "
                       "(no ucm2/)\n" % args.dir)

    ok, messages, validators = validate_tree(args.dir, args.card)
    print("== level 1: structural validation%s ==" % (
        " (card %s)" % args.card if args.card else ""))
    for msg in messages:
        print(msg)
    print("level 1: %s" % ("PASS" if ok else "FAIL"))
    if not ok:
        return 1

    if args.kernel:
        print("== level 1b: cset names and values against %s ==" % args.kernel)
        try:
            table = load_controls(args.kernel, sources, args.reg_bytes)
        except (OSError, CSourceError) as exc:
            print("level 1b: FAIL (cannot extract the control table: %s)"
                  % exc)
            return 1
        print("%d controls extracted from %s" % (len(table.ctls),
                                                 ", ".join(sources)))
        for note in table.notes:
            print("note: %s" % note)
        ok1b, msgs = table.check_validators(validators, args.dir)
        for msg in msgs:
            print(msg)
        print("level 1b: %s" % ("PASS" if ok1b else "FAIL"))
        if not ok1b:
            return 1
    else:
        print("level 1b: not run (use --kernel or T715_KERNEL_DIR)")

    if not args.docker:
        print("level 2/3: not run (use --docker)")
        return 0

    card = args.card or guess_card(args.dir)
    print("== level 2+3: docker %s (%s) ==" % (args.image, DOCKER_PLATFORM))
    proc = docker_validate(args.dir, [fv.path for fv in validators], card,
                           args.image)
    sys.stdout.write(proc.stdout)
    if proc.stderr:
        sys.stdout.write(proc.stderr)
    if proc.returncode == 0 and "load OK" in proc.stdout:
        print("level 2: PASS")
    else:
        print("level 2: FAIL (rc=%d)" % proc.returncode)
    print("level 3: NOT ACHIEVED (needs a kernel sound card; see the "
          "alsaucm attempt output above)")
    return 0 if proc.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
