#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Static safety checks on the loader sources and objects.
#   safety_check.sh OBJ_DIR [OBJDUMP]
# 1. no forbidden ioctl constant (0x6F32/34/35/36, any spelling) in src/;
# 2. no call that can make, extend, cut, rename or remove a file in src/,
#    except sl_state.c, which writes the CP state file under /run/ only;
# 3. the only write-capable open() calls are the boot node, the holder nodes,
#    /dev/kmsg and the /run/ state file; NV/EFS/sysfs paths are only opened
#    read-only;
# 4. objdump of the loader objects: no immediate 0x6f32/34/35/36.
set -eu

B=$1
OBJDUMP=${2:-objdump}
SRC=$(cd "$(dirname "$0")/../src" && pwd)
fails=0
ko() { echo "FAIL $*"; fails=$((fails + 1)); }

echo "-- forbidden ioctl constants in src/ (expect none)"
if grep -rniE '0x0*6f3[2456]|\b2846[689]\b|\b28470\b|_IO\([^)]*0x3[2456]\)|CP_UPLOAD|DUMP_RESET|DUMP_START|FORCE_CRASH' "$SRC"; then
	ko "forbidden ioctl constant or name in src/"
else
	echo "ok   none"
fi
echo "-- where the forbidden values do appear (test tripwires only):"
grep -rnE '0x6F3[2456]' "$SRC/../tests" | sed 's#.*/tests/#  tests/#' | cut -c1-110

echo "-- file-modifying calls in src/ outside sl_state.c (expect none)"
if grep -rnE --exclude=sl_state.c 'O_CREAT|O_TRUNC|O_APPEND|O_TMPFILE|\bcreat(64)?\(|\bfopen|\bfreopen|\brename(at2?)?\(|\bunlink(at)?\(|\btruncate\(|\bftruncate\(|\bmkdir(at)?\(|\brmdir\(|\bsymlink(at)?\(|\blink(at)?\(|\bchmod\(|\bfchmod\(|\bremove\(|\bpwrite|\bfwrite|\bsendfile|\bcopy_file_range|\bmmap\(' "$SRC"; then
	ko "file-modifying call in src/"
else
	echo "ok   none"
fi

echo "-- every open() call in src/ and its flags (comments excluded)"
code() { grep -rnE "$1" "$SRC" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(/\*|\*)'; }
code '\bopen\(' | sed "s#$SRC/#  src/#"
w=$(code '\bopen\(' | grep -cE 'O_WRONLY|O_RDWR' || true)
grep -nE 'fd = open\(path, O_RDWR \| O_CLOEXEC \| O_NOCTTY\);' "$SRC/sl_ops_linux.c" >/dev/null || ko "boot open changed"
grep -nE 'fd = open\(path, O_RDWR \| O_NONBLOCK \| O_CLOEXEC \| O_NOCTTY\);' "$SRC/sl_ops_linux.c" >/dev/null || ko "holder open changed"
grep -nE 'open\("/dev/kmsg", O_WRONLY' "$SRC/sl_main.c" >/dev/null || ko "kmsg open changed"
grep -nE 'fd = open\(tmp, O_WRONLY \| O_CREAT \| O_TRUNC \| O_NOFOLLOW \| O_CLOEXEC, 0644\);' "$SRC/sl_state.c" >/dev/null || ko "state file open changed"
if [ "$w" -ne 4 ]; then
	ko "expected exactly 4 write-capable open() calls, found $w"
else
	echo "ok   exactly 4 write-capable open() calls: boot node, holder nodes, /dev/kmsg, /run state file"
fi
echo "-- sl_state.c: the one file writer is confined to /run/"
grep -nE '#define STATE_PREFIX "/run/"' "$SRC/sl_state.c" >/dev/null || ko "state prefix is not /run/"
grep -nE 'if \(!sl_state_path_ok\(path\)\)' "$SRC/sl_state.c" >/dev/null || ko "state writer does not re-check its path"
grep -nE 'sl_state_path_ok\(c->state_file\)' "$SRC/sl_loader.c" >/dev/null || ko "config does not check the state path"
n=$(code 'sl_state_write\(' | grep -vc 'sl_state\.c\|sl_ops\.h' || true)
[ "$n" -eq 1 ] && echo "ok   sl_state_write() has one caller (ops state_publish), path checked at config and write time" || ko "sl_state_write callers: $n"
# the write-capable opens are only reached through boot_open/holder_open
for f in boot_open holder_open; do
	n=$(grep -rnE "ops?->$f\(|->$f\(o->ctx" "$SRC" | grep -vc 'sl_ops_linux.c' || true)
	echo "   $f call sites: $n"
done
if grep -nE 'boot_open|holder_open' "$SRC/sl_nv.c"; then
	ko "NV code reaches a writable open"
fi
# NV, manifest, md5, image and sysfs go through ro_open / sysfs_read only
if grep -nE '\bopen\(' "$SRC/sl_nv.c" "$SRC/sl_loader.c" "$SRC/sl_toc.c"; then
	ko "direct open() in loader logic"
else
	echo "ok   loader logic opens files only through ops->ro_open / ops->sysfs_read"
fi

echo "-- write() call sites in src/ (boot node, stderr, kmsg, /run state; comments excluded)"
code '\bwrite\(' | sed "s#$SRC/#  src/#"
if code '\bwrite\(' | grep -vE 'sl_log.c|sl_ops_linux.c|sl_state.c' | grep -q .; then
	ko "write() outside sl_log.c / sl_ops_linux.c / sl_state.c"
else
	echo "ok   write() only in sl_log.c (stderr, kmsg), sl_ops_linux.c (boot node), sl_state.c (/run state)"
fi

echo "-- objdump of the loader objects ($OBJDUMP)"
if ls "$B"/obj/*.o >/dev/null 2>&1; then
	if "$OBJDUMP" -d "$B"/obj/*.o | grep -iE '#0x6f3[2456]\b|#2846[689]\b|#28470\b'; then
		ko "forbidden immediate in the loader objects"
	else
		n=$("$OBJDUMP" -d "$B"/obj/*.o | grep -ciE '0x6f(19|20|22|23|24|27|28|29|37|47|48)\b' || true)
		echo "ok   no 0x6f32/34/35/36 immediate ($n allow-listed ioctl immediates seen)"
	fi
else
	ko "no objects in $B/obj"
fi

[ "$fails" -eq 0 ]
