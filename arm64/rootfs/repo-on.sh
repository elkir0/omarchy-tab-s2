#!/bin/bash
# repo-on.sh — the Omarchy image's pacman steps (steps 7, 8 and 11 of the
# Dockerfile). finalize.sh restored ALARM's pristine /etc/pacman.conf when the
# base image was finished; this brings back what setup-pacman.sh had for the
# build, from a fresh pristine copy, until finalize.sh runs again:
#   - no alpm sandbox, no download user, no free-space check under Docker;
#   - [t715-omarchy] (/repo, the local repository) before [core].
set -euo pipefail

CONF=/etc/pacman.conf

die() { printf 'repo-on: %s\n' "$*" >&2; exit 1; }

[ -f /repo/t715-omarchy.db ] || die "no /repo/t715-omarchy.db (local repository not mounted)"
[ -f "$CONF.t715-orig" ] || cp -a "$CONF" "$CONF.t715-orig"
cp -a "$CONF.t715-orig" "$CONF"

sed -i '/^\[options\]/a DisableSandbox' "$CONF"
sed -i -e 's/^CheckSpace/#CheckSpace/' -e 's/^DownloadUser/#DownloadUser/' "$CONF"

awk -v stanza='[t715-omarchy]
SigLevel = Optional TrustedOnly
Server = file:///repo' '
    !done && /^\[core\]$/ { print stanza; print ""; done = 1 }
    { print }
' "$CONF" > /tmp/pacman.conf.t715
cat /tmp/pacman.conf.t715 > "$CONF"
rm -f /tmp/pacman.conf.t715
repo_line="$(grep -n '^\[t715-omarchy\]$' "$CONF" | cut -d: -f1)"
core_line="$(grep -n '^\[core\]$' "$CONF" | head -n1 | cut -d: -f1)"
[ -n "$repo_line" ] && [ -n "$core_line" ] && [ "$repo_line" -lt "$core_line" ] \
    || die "could not declare [t715-omarchy] before [core]"
