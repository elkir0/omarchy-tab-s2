#!/bin/sh
# run.sh — build and run fsm-replay.c against the kernel branch's state machine
# (research/modem/LINK-PM.md section 6, step L0).  KDIR: a kernel tree with
# kernel/patches/t715-linkpm applied (default src/linux-6.12, from the repository root).
#   sh research/modem/linkpm/run.sh [-v]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KDIR=${KDIR:-src/linux-6.12}
b=$(mktemp -d "${TMPDIR:-/tmp}/fsm-replay.XXXXXX")
trap 'rm -rf "$b"' EXIT
cp -R "$here/stubs/." "$b/"
cp "$KDIR/drivers/misc/modem_v1/link_device_pm.c" "$KDIR/drivers/misc/modem_v1/link_device_pm.h" "$b/"
cp "$here/fsm-replay.c" "$b/"
${CC:-cc} -std=gnu11 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
	-I"$b" -o "$b/fsm-replay" "$b/fsm-replay.c"
"$b/fsm-replay" "$@"
