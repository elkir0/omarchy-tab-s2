#!/usr/bin/env bash
# Build the SM-T715 initramfs that boots the Arch image stored on USERDATA
# (see boot/initramfs/init and boot/README.md).
#
# Output: out/initramfs/initramfs.cpio.gz (+ manifest, SHA256SUMS)
#
# Archive contents (newc cpio, root:root, mtime 0, sorted, gzip -n -9):
#   /init                  boot/initramfs/init
#   /bin/busybox           static ARMv7 hard-float busybox from Debian's
#                          busybox-static armhf package (version + SHA-256
#                          pinned below)
#   applet symlinks        every applet of "busybox --list-full" except
#                          init/linuxrc, pointing at /bin/busybox
#   /sbin/e2fsck           static e2fsck from Debian's e2fsck-static armhf
#                          package (version + SHA-256 pinned below): /init
#                          checks USERDATA before a read-write mount
#                          (persistent root)
#   /dev/console           char 5:1 (the kernel opens it for /init's stdio)
#   /etc/t715-initramfs.id build identification, logged at boot
#   /etc/t715-knobs        only with --knobs (defaults for the t715.* knobs;
#                          the kernel command line still wins)
#   /lib/t715-modules/*.ko only with --modules: the GPU modules (gpu-sched,
#                          panfrost) of the kernel build, inserted by /init
#                          after its watchdog guard (built in, panfrost's
#                          probe would run before it: boot loop if it hangs)
#   /lib/modules/RELEASE/  only with --modules: the whole module tree of the
#                          kernel build (modules.dep, aliases), which /init
#                          copies into the root's tmpfs layer so that udev
#                          loads Bluetooth, Wi-Fi... (the image has none)
#   /lib/t715-paramrescue/ only with --paramrescue: the part of a PARAM image
#                          that is a loader known to work (param.img.gz,
#                          gzipped), two sha256 (loader.sha256, stock.sha256)
#                          and its length (extent); with --paramrescue-also,
#                          also.sha256, the sha256 of loaders only left
#                          alone.  /init then puts the first loader back in
#                          PARAM when that part of PARAM holds none of them
#                          (t715.paramrescue, on by default with the option).
#                          A tablet's own PARAM is never published: keep
#                          such a build private.
#   /lib/t715-golden/      only with --golden DIR: the installer of the 64-bit
#                          system (t715.golden, on by default with the
#                          option): logo.jpg, the loader's forged logo that
#                          /init puts in the tablet's own PARAM in place of
#                          Samsung's; stock.sha256 and loader.sha256, those of
#                          PARAM's first EXTENT bytes before and after, one
#                          line per stock PARAM the installer knows (the two
#                          of T715XXU2CRH1), paired by line number;
#                          stock.members, the members of one stock archive
#                          (sha256, size, name each), to say on screen how
#                          a PARAM it does not know differs;
#                          extent; bootloader, the one bootloader the loader
#                          is made for; release, the installer's version.
#                          No byte of Samsung's in it: this build is public.
#   empty dirs             proc sys run tmp newroot userdata ...
#
# Usage: bash boot/build-initramfs.sh [--out DIR] [--knobs "t715.shell=1 ..."]
#                                        [--modules BUILD/modules.tar.xz]
#                                        [--paramrescue PARAM_IMG --paramrescue-stock SHA256
#                                         [--paramrescue-extent BYTES]
#                                         [--paramrescue-also PARAM_IMG ...]]
#                                        [--golden DIR]
#
# Everything runs in Docker (native arm64 Debian trixie, pinned by digest):
# hash-checked download, `file`/`readelf` checks, applet list, cpio
# assembly with boot/cpio_newc.py, gzip -n.  The .deb is cached in
# out/initramfs/cache/.  Same inputs => byte-identical output.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out/initramfs"
CACHE="$ROOT/out/initramfs/cache"
INIT_SRC="$ROOT/boot/initramfs/init"
CPIO_PY="$ROOT/boot/cpio_newc.py"
KNOBS=""
MODULES_TAR=""
PARAMRESCUE=""
PARAMRESCUE_STOCK=""
PARAMRESCUE_EXTENT=""
PARAMRESCUE_ALSO=()
GOLDEN=""

# Debian trixie image index (multi-arch), pinned; used as linux/arm64.
BASE_IMAGE="debian@sha256:8c4733a92aacd0bcff3779eadc35a4a5147f36cb20a5fcb56504cbc740212259"
TOOLS_IMAGE="t715-initramfs-tools:1"
BB_VERSION="1:1.37.0-6+b9"
BB_DEB="busybox-static_1.37.0-6+b9_armhf.deb"
BB_SHA256="8b35210e08d559ecc0ddb660dd96f6f9694f69eb27f1dc608f5eeda56d94509e"
BB_URLS=(
  "http://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-6%2Bb9_armhf.deb"
  "http://snapshot.debian.org/archive/debian/20261020T000000Z/pool/main/b/busybox/busybox-static_1.37.0-6%2Bb9_armhf.deb"
)
FSCK_VERSION="1.47.2-3+b12"
FSCK_DEB="e2fsck-static_1.47.2-3+b12_armhf.deb"
FSCK_SHA256="2a84974a774a65122c83bfb66e31e1a24cc19d9d9b689e0092381d9575162324"
FSCK_URLS=(
  "http://deb.debian.org/debian/pool/main/e/e2fsprogs/e2fsck-static_1.47.2-3%2Bb12_armhf.deb"
  "http://snapshot.debian.org/archive/debian/20261020T000000Z/pool/main/e/e2fsprogs/e2fsck-static_1.47.2-3%2Bb12_armhf.deb"
)

usage() { sed -n '2,60p' "$0"; }
die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || die "--out needs a value"; OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --knobs) [[ $# -ge 2 ]] || die "--knobs needs a value"; KNOBS="$2"; shift 2 ;;
    --modules) [[ $# -ge 2 ]] || die "--modules needs a value"; MODULES_TAR="$2"; shift 2 ;;
    --paramrescue) [[ $# -ge 2 ]] || die "--paramrescue needs a value"; PARAMRESCUE="$2"; shift 2 ;;
    --paramrescue=*) PARAMRESCUE="${1#--paramrescue=}"; shift ;;
    --paramrescue-stock) [[ $# -ge 2 ]] || die "--paramrescue-stock needs a value"; PARAMRESCUE_STOCK="$2"; shift 2 ;;
    --paramrescue-stock=*) PARAMRESCUE_STOCK="${1#--paramrescue-stock=}"; shift ;;
    --paramrescue-extent) [[ $# -ge 2 ]] || die "--paramrescue-extent needs a value"; PARAMRESCUE_EXTENT="$2"; shift 2 ;;
    --paramrescue-extent=*) PARAMRESCUE_EXTENT="${1#--paramrescue-extent=}"; shift ;;
    --paramrescue-also) [[ $# -ge 2 ]] || die "--paramrescue-also needs a value"; PARAMRESCUE_ALSO+=("$2"); shift 2 ;;
    --paramrescue-also=*) PARAMRESCUE_ALSO+=("${1#--paramrescue-also=}"); shift ;;
    --golden) [[ $# -ge 2 ]] || die "--golden needs a value"; GOLDEN="$2"; shift 2 ;;
    --golden=*) GOLDEN="${1#--golden=}"; shift ;;
    --knobs=*) KNOBS="${1#--knobs=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

for w in $KNOBS; do
  [[ "$w" =~ ^t715\.[a-z]+(=[^[:space:]]*)?$ ]] || die "--knobs: '$w' is not a t715.* knob"
done
ALSO_NOTE=
[[ ${#PARAMRESCUE_ALSO[@]} -eq 0 || -n "$PARAMRESCUE" ]] || die "--paramrescue-also goes with --paramrescue"
[[ -f "$INIT_SRC" ]] || die "missing $INIT_SRC"
[[ -f "$CPIO_PY" ]] || die "missing $CPIO_PY"
mkdir -p "$OUT" "$CACHE"
OUT="$(cd "$OUT" && pwd)"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- the loader the rescue puts back (t715.paramrescue) --------------------
# --paramrescue IMG --paramrescue-stock SHA256: IMG is a PARAM image with a
# loader known to work; SHA256 is that of the tablet's stock PARAM, which the
# rescue leaves alone.  Without that hash the rescue would take the stock
# image for a loader that did not run.  The option turns the knob on unless
# --knobs sets it.
# --paramrescue-extent BYTES: only the first BYTES of the image are the
# loader (the archive S-Boot reads its logo from), and both sha256 are of
# those bytes.  S-Boot writes its own data at the end of PARAM whenever it
# boots a kernel itself (seen 2026-11-25), so a loader followed by such
# data would else be taken for none.  The rest of PARAM is then never read
# nor written by the rescue.  Default: the whole image.
# --paramrescue-also IMG (more than once): other PARAM images with loaders
# that work, of the same extent: the rescue leaves them alone too (their
# sha256 go to also.sha256) and never writes them.
PRDIR="$(mktemp -d)"
PRSHA=""
if [[ -n "$PARAMRESCUE" ]]; then
  [[ -f "$PARAMRESCUE" ]] || die "--paramrescue: $PARAMRESCUE not found"
  [[ "$PARAMRESCUE_STOCK" =~ ^[0-9a-fA-F]{64}$ ]] || die "--paramrescue needs --paramrescue-stock SHA256 (that of the stock PARAM)"
  PARAMRESCUE="$(cd "$(dirname "$PARAMRESCUE")" && pwd)/$(basename "$PARAMRESCUE")"
  if [[ -z "$PARAMRESCUE_EXTENT" ]]; then
    PARAMRESCUE_EXTENT=$(wc -c <"$PARAMRESCUE" | tr -d ' ')
  fi
  [[ "$PARAMRESCUE_EXTENT" =~ ^[1-9][0-9]*$ && "$PARAMRESCUE_EXTENT" -le "$(wc -c <"$PARAMRESCUE" | tr -d ' ')" ]] \
    || die "--paramrescue-extent: a number of bytes, at most the image's ($(wc -c <"$PARAMRESCUE" | tr -d ' '))"
  head -c "$PARAMRESCUE_EXTENT" "$PARAMRESCUE" >"$PRDIR/param.img"
  gzip -n -9 -c "$PRDIR/param.img" >"$PRDIR/param.img.gz"
  PRSHA="$(sha256_of "$PRDIR/param.img")"
  rm -f "$PRDIR/param.img"
  printf '%s\n' "$PRSHA" >"$PRDIR/loader.sha256"
  printf '%s\n' "$PARAMRESCUE_STOCK" | tr 'A-F' 'a-f' >"$PRDIR/stock.sha256"
  printf '%s\n' "$PARAMRESCUE_EXTENT" >"$PRDIR/extent"
  # shellcheck disable=SC2207  # the idiom for a possibly empty array under set -u, bash 3.2 included
  for also in ${PARAMRESCUE_ALSO[@]+"${PARAMRESCUE_ALSO[@]}"}; do
    [[ -f "$also" ]] || die "--paramrescue-also: $also not found"
    head -c "$PARAMRESCUE_EXTENT" "$also" >"$PRDIR/also.img"
    sha256_of "$PRDIR/also.img" >>"$PRDIR/also.sha256"
  done
  rm -f "$PRDIR/also.img"
  ALSO_NOTE=
  if [[ ${#PARAMRESCUE_ALSO[@]} -gt 0 ]]; then ALSO_NOTE=", ${#PARAMRESCUE_ALSO[@]} left alone"; fi
  case " $KNOBS " in
  *" t715.paramrescue="*) ;;
  *) KNOBS="${KNOBS:+$KNOBS }t715.paramrescue=1" ;;
  esac
fi

# --- the installer of the 64-bit system (t715.golden) ----------------------
# --golden DIR: DIR holds logo.jpg (the loader's logo, as the loader's build
# writes it next to its PARAM image), stock.sha256 and loader.sha256 (the
# sha256 of PARAM's first EXTENT bytes as the firmware ships them, and once
# logo.jpg replaces Samsung's: the installer writes nothing else; one line per
# stock PARAM the installer knows, paired by line number), extent,
# bootloader and release (one word each).  Checked here, packed as they are.
GDIR="$(mktemp -d)"
GOLDEN_NOTE=""
if [[ -n "$GOLDEN" ]]; then
  [[ -d "$GOLDEN" ]] || die "--golden: $GOLDEN is not a directory"
  for f in logo.jpg stock.sha256 loader.sha256 stock.members extent bootloader release; do
    [[ -s "$GOLDEN/$f" ]] || die "--golden: $GOLDEN/$f is missing or empty"
    cp "$GOLDEN/$f" "$GDIR/$f"
  done
  # golden_lines FILE: how many lines of FILE hold a word, when every one of
  # them is a lower-case sha256 (a label may follow); "bad N" when line N is
  # not.  Lines of blanks only are not counted, as the installer counts them.
  golden_lines() {
    local n=0 l w
    while IFS= read -r l || [[ -n "$l" ]]; do
      w="${l#"${l%%[![:space:]]*}"}"
      w="${w%%[[:space:]]*}"
      [[ -n "$w" ]] || continue
      n=$((n + 1))
      [[ "$w" =~ ^[0-9a-f]{64}$ ]] || { echo "bad $n"; return 0; }
    done <"$1"
    echo "$n"
  }
  # (not "local": this is not inside a function)
  gs="$(golden_lines "$GDIR/stock.sha256")"
  gl="$(golden_lines "$GDIR/loader.sha256")"
  [[ "$gs" != bad* ]] || die "--golden: stock.sha256: line ${gs#bad } does not start with a lower-case sha256"
  [[ "$gl" != bad* ]] || die "--golden: loader.sha256: line ${gl#bad } does not start with a lower-case sha256"
  [[ "$gs" -ge 1 && "$gs" = "$gl" ]] \
    || die "--golden: stock.sha256 has $gs stock PARAM(s) and loader.sha256 $gl: one loader per stock PARAM, on the same line"
  [[ "$(head -n 1 "$GDIR/extent")" =~ ^[1-9][0-9]*$ ]] || die "--golden: extent is not a number of bytes"
  if grep -q -v -E '^[0-9a-f]{64} [0-9]+ [A-Za-z0-9._-]+$' "$GDIR/stock.members"; then
    die "--golden: stock.members has a line that is not \"SHA256 SIZE NAME\""
  fi
  [[ "$(head -n 1 "$GDIR/bootloader")" =~ ^[A-Z0-9]+$ ]] || die "--golden: bootloader is not a firmware version"
  [[ "$(head -n 1 "$GDIR/release")" =~ ^[0-9A-Za-z.+-]+$ ]] || die "--golden: release is not a version"
  [[ "$(head -c 2 "$GDIR/logo.jpg" | od -An -tx1 | tr -d ' ')" == ffd8 ]] || die "--golden: logo.jpg is not a JPEG"
  [[ $(wc -c <"$GDIR/logo.jpg") -le 1048576 ]] || die "--golden: logo.jpg is over 1 MiB"
  GOLDEN_NOTE=", golden: installer $(head -n 1 "$GDIR/release") for $(head -n 1 "$GDIR/bootloader"), $gs stock PARAM(s), loader sha256:$(head -c 12 "$GDIR/loader.sha256")"
  case " $KNOBS " in
  *" t715.golden="*) ;;
  *) KNOBS="${KNOBS:+$KNOBS }t715.golden=1" ;;
  esac
fi

# --- tools image (file, readelf, python3; shellcheck for the tests) -------
if ! docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1; then
  echo ">>> building Docker image $TOOLS_IMAGE"
  docker build --platform linux/arm64 -t "$TOOLS_IMAGE" - <<EOF
FROM $BASE_IMAGE
RUN apt-get update \\
 && apt-get install -y --no-install-recommends file binutils python3 shellcheck \\
 && rm -rf /var/lib/apt/lists/*
EOF
fi

# --- busybox-static and e2fsck-static .debs, hash-pinned ------------------
# fetch_deb FILE SHA256 URL...: into the cache, checked.
fetch_deb() {
  local file=$1 sum=$2 url deb
  shift 2
  deb="$CACHE/$file"
  if [[ ! -f "$deb" || "$(sha256_of "$deb")" != "$sum" ]]; then
    rm -f "$deb"
    for url in "$@"; do
      echo ">>> downloading $url"
      if docker run --rm --platform linux/arm64 -v "$CACHE:/cache" "$TOOLS_IMAGE" \
          sh -ec '/usr/lib/apt/apt-helper download-file "$1" /tmp/x.deb "SHA256:$2" >/dev/null
                  cp /tmp/x.deb "/cache/$3.part"' sh "$url" "$sum" "$file"; then
        mv "$deb.part" "$deb"
        break
      fi
      rm -f "$deb.part"
    done
  fi
  [[ -f "$deb" ]] || die "could not download $file"
  [[ "$(sha256_of "$deb")" == "$sum" ]] || die "$deb: SHA-256 mismatch"
}
fetch_deb "$BB_DEB" "$BB_SHA256" "${BB_URLS[@]}"
fetch_deb "$FSCK_DEB" "$FSCK_SHA256" "${FSCK_URLS[@]}"
DEB="$CACHE/$BB_DEB"
FSCK="$CACHE/$FSCK_DEB"

# --- assemble in the container --------------------------------------------
INIT_SHA="$(sha256_of "$INIT_SRC")"
# GPU modules, in load order (file names sort in that order).
MODDIR="$(mktemp -d)"
MODTREE="$(mktemp -d)"
trap 'rm -rf "$MODDIR" "$MODTREE" "$PRDIR" "$GDIR"' EXIT
MODREL=""
MODSHA=""
if [[ -n "$MODULES_TAR" ]]; then
  [[ -f "$MODULES_TAR" ]] || die "--modules: $MODULES_TAR not found"
  for spec in 10:drivers/gpu/drm/scheduler/gpu-sched.ko 20:drivers/gpu/drm/panfrost/panfrost.ko; do
    n=${spec%%:*}; rel=${spec#*:}
    path=$(tar -tJf "$MODULES_TAR" | grep -m1 "/kernel/$rel\$") || die "--modules: $rel not in $MODULES_TAR"
    tar -xJf "$MODULES_TAR" -O "$path" >"$MODDIR/$n-$(basename "$rel")"
  done
  # The whole tree, for the root filesystem (exactly one release).
  tar -C "$MODTREE" -xJf "$MODULES_TAR"
  set -- "$MODTREE"/lib/modules/*/
  [[ $# -eq 1 && -f "$1/modules.dep" ]] || die "--modules: expected one lib/modules/RELEASE with modules.dep in $MODULES_TAR"
  MODREL=$(basename "$1")
  MODSHA="$(sha256_of "$MODULES_TAR")"
fi
# The modules' tarball hash names the tree: /init refreshes a persistent
# root's copy when it changes (same release string, other build).
BUILD_ID="init sha256:${INIT_SHA:0:12}, busybox-static $BB_VERSION armhf, e2fsck-static $FSCK_VERSION armhf${KNOBS:+, knobs: $KNOBS}${MODULES_TAR:+, modules: gpu-sched panfrost + lib/modules/$MODREL (sha256:${MODSHA:0:12})}${PRSHA:+, paramrescue: the first ${PARAMRESCUE_EXTENT} bytes of PARAM, sha256:${PRSHA:0:12}}$ALSO_NOTE$GOLDEN_NOTE"

# shellcheck disable=SC2016  # expanded by the container's bash
docker run --rm --platform linux/arm64 \
  -v "$DEB:/in/busybox.deb:ro" -v "$FSCK:/in/e2fsck.deb:ro" -v "$INIT_SRC:/in/init:ro" -v "$CPIO_PY:/in/cpio_newc.py:ro" \
  -v "$MODDIR:/in/modules:ro" -v "$MODTREE:/in/modtree:ro" -v "$PRDIR:/in/paramrescue:ro" -v "$GDIR:/in/golden:ro" -v "$OUT:/out" -e KNOBS="$KNOBS" -e BUILD_ID="$BUILD_ID" "$TOOLS_IMAGE" bash -euo pipefail -c '
cd /tmp
dpkg-deb -x /in/busybox.deb deb
dpkg-deb -x /in/e2fsck.deb fsckdeb
bb=deb/usr/bin/busybox
[ -f "$bb" ] || bb=deb/bin/busybox
fsck=fsckdeb/usr/sbin/e2fsck.static
[ -f "$fsck" ] || fsck=fsckdeb/sbin/e2fsck.static
for b in "$bb" "$fsck"; do
  desc=$(file -b "$b")
  flags=$(readelf -h "$b" | sed -n "s/^ *Flags: *//p")
  echo ">>> file:    ${b##*/}: $desc"
  echo ">>> readelf: ${b##*/}: Flags: $flags"
  case $desc in
    "ELF 32-bit LSB executable, ARM, EABI5"*"statically linked"*) ;;
    *) echo "error: ${b##*/} is not a static ARM EABI5 executable" >&2; exit 1 ;;
  esac
  case $flags in
    *"Version5 EABI"*"hard-float ABI"*) ;;
    *) echo "error: ${b##*/} is not EABI5 hard-float" >&2; exit 1 ;;
  esac
  if readelf -l "$b" | grep -q "Requesting program interpreter"; then
    echo "error: ${b##*/} has a program interpreter (dynamic)" >&2; exit 1
  fi
done
"$fsck" -V >/dev/null 2>&1 || { echo "error: cannot run the armhf e2fsck" >&2; exit 1; }
# Runs through the Docker VM qemu-arm binfmt handler.
if ! "$bb" --list-full >applets 2>/dev/null || [ ! -s applets ]; then
  echo "error: cannot run the armhf busybox (qemu-arm binfmt missing?)" >&2; exit 1
fi
"$bb" sh -n /in/init || { echo "error: /init has a syntax error" >&2; exit 1; }
printf "%s\n" "$BUILD_ID" >build-id
printf "%s" "$KNOBS" >knobs

python3 -I - "$bb" "$fsck" applets build-id knobs /tmp/initramfs.cpio <<"PY"
import sys
sys.path.insert(0, "/in")
import cpio_newc as c

bb, fsck, applets, build_id, knobs, out = sys.argv[1:7]
items = {}  # name -> (mode, data, rdevmajor, rdevminor)
for d in ("bin", "dev", "etc", "newroot", "proc", "run", "sbin", "sys",
          "userdata", "usr", "usr/bin", "usr/sbin"):
    items[d] = (0o040755, b"", 0, 0)
items["tmp"] = (0o041777, b"", 0, 0)
items["dev/console"] = (0o020600, b"", 5, 1)
items["init"] = (0o100755, open("/in/init", "rb").read(), 0, 0)
items["bin/busybox"] = (0o100755, open(bb, "rb").read(), 0, 0)
items["sbin/e2fsck"] = (0o100755, open(fsck, "rb").read(), 0, 0)
items["etc/t715-initramfs.id"] = (0o100644, open(build_id, "rb").read(), 0, 0)
k = open(knobs, "rb").read().strip()
if k:
    items["etc/t715-knobs"] = (0o100644, k + b"\n", 0, 0)
import os
mods = sorted(os.listdir("/in/modules"))
if mods:
    items["lib"] = (0o040755, b"", 0, 0)
    items["lib/t715-modules"] = (0o040755, b"", 0, 0)
for m in mods:
    items["lib/t715-modules/" + m] = (0o100644, open("/in/modules/" + m, "rb").read(), 0, 0)
# Module tree (lib/modules/RELEASE), regular files and dirs only: the
# build/source links of modules_install point into the build machine.
tree = "/in/modtree/lib/modules"
if os.path.isdir(tree):
    items["lib"] = (0o040755, b"", 0, 0)
    items["lib/modules"] = (0o040755, b"", 0, 0)
    for top, dirs, files in os.walk(tree):
        dirs.sort()
        rel = os.path.relpath(top, "/in/modtree")
        items[rel] = (0o040755, b"", 0, 0)
        for f in sorted(files):
            p = os.path.join(top, f)
            if os.path.islink(p):
                continue
            items[os.path.join(rel, f)] = (0o100644, open(p, "rb").read(), 0, 0)
# The loader the rescue puts back (boot/build-initramfs.sh --paramrescue).
pr = "/in/paramrescue"
for f in ("param.img.gz", "loader.sha256", "stock.sha256", "extent", "also.sha256"):
    if os.path.exists(os.path.join(pr, f)):
        items.setdefault("lib", (0o040755, b"", 0, 0))
        items.setdefault("lib/t715-paramrescue", (0o040755, b"", 0, 0))
        items["lib/t715-paramrescue/" + f] = (0o100644, open(os.path.join(pr, f), "rb").read(), 0, 0)
# The installer of the 64-bit system (boot/build-initramfs.sh --golden).
gd = "/in/golden"
for f in ("logo.jpg", "stock.sha256", "loader.sha256", "stock.members", "extent", "bootloader", "release"):
    if os.path.exists(os.path.join(gd, f)):
        items.setdefault("lib", (0o040755, b"", 0, 0))
        items.setdefault("lib/t715-golden", (0o040755, b"", 0, 0))
        items["lib/t715-golden/" + f] = (0o100644, open(os.path.join(gd, f), "rb").read(), 0, 0)
for line in open(applets):
    path = line.strip()
    if not path or path in ("linuxrc", "sbin/init") or path in items:
        continue
    if path.split("/")[0] not in ("bin", "sbin", "usr"):
        raise SystemExit("unexpected applet path %r" % path)
    items[path] = (0o120777, b"/bin/busybox", 0, 0)

entries = []
for ino, name in enumerate(sorted(items), start=1):
    mode, data, rmaj, rmin = items[name]
    entries.append(c.Entry(name, data=data, mode=mode, ino=ino,
                           nlink=2 if mode & 0o170000 == 0o040000 else 1,
                           mtime=0, rdevmajor=rmaj, rdevminor=rmin))
blob = c.write_archive(entries)
blob += b"\0" * (-len(blob) % 512)
open(out, "wb").write(blob)
print(">>> cpio: %d entries, %d bytes" % (len(entries), len(blob)))
PY

gzip -n -9 -c /tmp/initramfs.cpio >/out/initramfs.cpio.gz
python3 -I /in/cpio_newc.py list /tmp/initramfs.cpio >/out/initramfs.manifest.txt
cd /out && sha256sum initramfs.cpio.gz >SHA256SUMS
'

SIZE=$(wc -c <"$OUT/initramfs.cpio.gz" | tr -d ' ')
echo ">>> $BUILD_ID"
echo ">>> $OUT/initramfs.cpio.gz: $SIZE bytes ($((SIZE / 1024)) KiB)"
cat "$OUT/SHA256SUMS"
