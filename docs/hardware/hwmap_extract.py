#!/usr/bin/env python3
"""Extract enabled `compatible` nodes from a plain `dtc` decompiled DTS.

Parses the stock Samsung SM-T715 device tree dump (`01_dumps/live_fdt.dts`,
output of `dtc -I dtb -O dts`) and lists every node that:

  * carries a `compatible` property, and
  * is enabled: `status` absent, `= "okay"` or `= "ok"` (dtc emits both
    spellings; the Samsung 3.10 kernel accepts "ok" as well as "okay").

For each such node the report gives the full path (root-relative, in
deterministic lexicographic order of path), the unit address when the node
name carries one, the ordered list of `compatible` strings, and the first
cell pair of `reg` (base address) when present.

Usage:
    python3 hwmap_extract.py <dts-file> [--csv]

Markdown is the default output; `--csv` switches to a machine-readable
variant (one row per node, header included).
"""

import argparse
import csv
import re
import sys

# Tokeniser: node name, property name, a bare value, or a single line of a
# bracketed (bytestring / cell) value.  Values in dtc output are one per
# line and end with ';', possibly carrying trailing cells as here:
#     reg = <0x15060000 0x1000>;
NODE_RE = re.compile(r'^\s*(/|[A-Za-z0-9,._+@/-]+)\s*\{')
PROP_RE = re.compile(r'^\s*([A-Za-z0-9,._+#-]+)\s*=\s*(.*)$')
DEAD_PROP_RE = re.compile(r'^\s*([A-Za-z0-9,._+#-]+)\s*;\s*$')
# strip comments / trailing whitespace
COMMENT_RE = re.compile(r'/\*.*?\*/|//[^\n]*')


def strip_comments(line):
    return COMMENT_RE.sub('', line)


def parse_value(raw):
    """Return the value as a string, without trailing ';' and whitespace."""
    return raw.strip().rstrip(';').strip()


class Node:
    __slots__ = ("name", "path", "parent", "children", "props", "line")

    def __init__(self, name, path, parent, line):
        self.name = name
        self.path = path
        self.parent = parent
        self.children = {}
        self.props = {}
        self.line = line

    def first_reg(self):
        """First cell pair of `reg`, formatted '0x.... 0x....'."""
        v = self.props.get("reg")
        if not v:
            return ""
        cells = re.findall(r'0[xX][0-9a-fA-F]+', v)
        if len(cells) >= 2:
            return cells[0] + " " + cells[1]
        if cells:
            return cells[0]
        return ""


def parse_dts(text):
    """Parse a dtc-decompiled DTS into a tree; returns (root, all_nodes).

    Deliberately not a full DTS parser: dtc output is regular enough that
    line-oriented scanning is reliable.  Labels (`label: name@addr {`) are
    stripped; `phandle` / `linux,phandle` references stay as-is.
    """
    root = None
    stack = []
    pending_labels = ""
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = strip_comments(raw)
        if not line.strip():
            continue
        s = line.strip()

        # `label: node-name {` — accumulate the label, the name comes next.
        m = re.match(r'^([A-Za-z_][\w-]*)\s*:\s*$', s)
        if m:
            pending_labels = m.group(1) + ": "
            continue

        m = NODE_RE.match(line)
        if m:
            name = m.group(1)
            # A node header may carry inline properties after the brace
            # (rare in dtc output); we only care about the name.
            path = (stack[-1].path + "/" + name) if stack else ""
            node = Node(name, path, stack[-1] if stack else None, lineno)
            if stack:
                # dtc decompiles duplicate names with a suffix (name@1);
                # keep the first occurrence, log nothing.
                if name in stack[-1].children:
                    i = 2
                    while f"{name}~{i}" in stack[-1].children:
                        i += 1
                    node.name = f"{name}~{i}"
                    node.path = stack[-1].path + "/" + node.name
                stack[-1].children[node.name] = node
            else:
                root = node
            stack.append(node)
            pending_labels = ""
            continue

        if s == "};" or s == "}":
            if stack:
                stack.pop()
            continue

        m = PROP_RE.match(line)
        if m and stack:
            stack[-1].props[m.group(1)] = parse_value(m.group(2))
            continue
        m = DEAD_PROP_RE.match(line)
        if m and stack:
            stack[-1].props[m.group(1)] = ""
            continue
        # Any other line (continuation of a multi-line value, `__symbols__`
        # entries, …) is ignored on purpose.
    return root


def enabled(node):
    """True when the node is enabled (status absent / "okay" / "ok")."""
    st = node.props.get("status")
    if st is None:
        return True
    st = st.strip('"')
    return st in ("okay", "ok")


def collect(root):
    out = []
    if root is None:
        return out

    def walk(n):
        for child in n.children.values():
            if "compatible" in child.props:
                if enabled(child):
                    out.append(child)
            walk(child)

    walk(root)
    out.sort(key=lambda n: n.path)
    return out


def compat_list(node):
    v = node.props.get("compatible", "")
    return [s.strip() for s in re.findall(r'"([^"]*)"', v)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dts", help="decompiled DTS file (dtc output)")
    ap.add_argument("--csv", action="store_true", help="emit CSV instead of Markdown")
    args = ap.parse_args()

    try:
        with open(args.dts, "r", errors="replace") as f:
            text = f.read()
    except OSError as e:
        print(f"error: cannot read {args.dts}: {e}", file=sys.stderr)
        return 1

    root = parse_dts(text)
    nodes = collect(root)

    if args.csv:
        w = csv.writer(sys.stdout)
        w.writerow(["path", "unit_address", "compatible", "reg"])
        for n in nodes:
            m = re.match(r'^(.*)@([0-9A-Za-z_+-]+)$', n.name)
            unit = m.group(2) if m else ""
            w.writerow([n.path, unit, ";".join(compat_list(n)), n.first_reg()])
        return 0

    # Markdown
    print("| Path | Unit addr | Compatible | Reg |")
    print("|---|---|---|---|")
    for n in nodes:
        m = re.match(r'^(.*)@([0-9A-Za-z_+-]+)$', n.name)
        unit = m.group(2) if m else ""
        comp = ", ".join(f"`{c}`" for c in compat_list(n))
        print(f"| `{n.path}` | {unit} | {comp} | {n.first_reg() or '—'} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
