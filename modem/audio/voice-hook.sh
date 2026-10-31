#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shannond --audio-hook for the SM-T715 card (README.md, G20):
#   voice-hook.sh open|close 8000|16000 PATH
# open (first open, and on a narrowband/wideband change): switches off, rate,
# switches on; close: switches off before the CP stops the AIF2 clocks.
# The "Voice Call" UCM verb (routes only) must be active; with
# VOICE_HOOK_UCM=1 the hook sets it itself (PipeWire must not hold the card).
CARD=${VOICE_HOOK_CARD:-wm1814}
ctl() { amixer -q -c "$CARD" cset "name=$1" "$2"; }
pins_off() { ctl 'Modem TX Switch' off; ctl 'Modem RX Switch' off; }
case "$1" in
open)
	case "$2" in 16000) rate=16kHz ;; *) rate=8kHz ;; esac
	if [ "${VOICE_HOOK_UCM:-0}" = 1 ]; then
		case "$3" in headphone|headset) dev=Headphones ;; *) dev=Speaker ;; esac
		alsaucm -c "$CARD" set _verb "Voice Call" set _enadev "$dev" set _enadev Mic || exit 1
	fi
	pins_off
	ctl 'Modem Rate' "$rate" || exit 1
	ctl 'Modem RX Switch' on
	ctl 'Modem TX Switch' on
	;;
close)
	pins_off
	;;
*)
	echo "usage: $0 open|close RATE PATH" >&2
	exit 2
	;;
esac
