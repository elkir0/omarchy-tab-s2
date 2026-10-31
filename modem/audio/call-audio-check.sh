#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Call audio checks without a far end (README.md, G20). Root on the tablet,
# shannond running with --audio-hook, PipeWire stopped.
#
#   call-audio-check.sh downlink NUMBER SECONDS OUT.wav
#       calls NUMBER and records the downlink: ASRC2L -> AIF1TX1 -> capture
#       of hw:wm1814,0 (left channel)
#   call-audio-check.sh deposit NUMBER OUT.wav [TONE_AT] [BURSTS]
#       calls NUMBER (the own line: busy -> voicemail), records the downlink,
#       and TONE_AT s after "active" sends BURSTS bursts of the codec 1 kHz
#       tone (0.4 s on, 0.4 s off) on the uplink instead of the microphone
#
# Then call the voicemail with "downlink" and look for the bursts with
# modem/tools/wavfine.py: a steady tone is cut by the CP's noise processing
# after about 1.5 s, the bursts come back whole. AIF1TX2 keeps the tone
# generator 2 as a source: with no powered AIF1TX input, DAPM keeps AIF1 off
# and arecord fails with EIO.
set -u
CARD=wm1814
C="env PYTHONPATH=/usr/lib/shannond python3 /usr/lib/shannond/bin/shannonctl --timeout 30"
ctl() { amixer -q -c "$CARD" cset "name=$1" "$2"; }
t0=$(date +%s)
ts() { echo "t=$(( $(date +%s) - t0 ))s $*"; }
wait_active() {
	last=""
	for i in $(seq 1 40); do
		sleep 1
		st=$($C call list | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c[0]["state"] if c else "none")')
		[ "$st" != "$last" ] && ts "call $st" && last=$st
		[ "$st" = active ] && return 0
		[ "$st" = none ] && [ "$i" -gt 3 ] && return 1
	done
	return 1
}

mode=${1:-}; num=${2:-}
case "$mode" in
downlink) secs=${3:?seconds}; out=${4:?output}; rec=$((secs + 8)) ;;
deposit) out=${3:?output}; tone_at=${4:-19}; bursts=${5:-12}; rec=$((tone_at + bursts + 25)) ;;
*) sed -n '3,20p' "$0"; exit 2 ;;
esac
[ -n "$num" ] || { echo "no number" >&2; exit 2; }

ctl 'AIF1TX2 Input 1' 'Tone Generator 2'
ctl 'AIF1TX1 Input 1' ASRC2L
ctl 'AIF1TX1 Input 1 Volume' 32
arecord -q -D "hw:$CARD,0" -c 2 -r 48000 -f S16_LE -d "$rec" "$out" &
recpid=$!
sleep 1
$C call dial "$num" >/dev/null && ts dialled
if wait_active; then
	if [ "$mode" = downlink ]; then
		sleep "$secs"
	else
		sleep "$tone_at"
		ts "uplink bursts start"
		i=0
		while [ $i -lt "$bursts" ]; do
			ctl 'ASRC1L Input' 'Tone Generator 1'; sleep 0.4
			ctl 'ASRC1L Input' None; sleep 0.4
			i=$((i + 1))
		done
		ts "uplink bursts end"
		sleep 2
	fi
	$C call hangup >/dev/null && ts "hung up"
else
	ts "no active call"
fi
sleep 2
kill "$recpid" 2>/dev/null
wait "$recpid" 2>/dev/null
ctl 'AIF1TX1 Input 1' None
ctl 'AIF1TX2 Input 1' None
