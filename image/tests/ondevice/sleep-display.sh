#!/bin/sh
# sleep-display.sh -- the display after a wake: N real sleeps, each followed
# at once by a screen-on, as a key wake gives one, and the display's
# timeouts counted.  Run as root ON THE TABLET, unattended, on battery,
# nobody touching it:
#
#   systemd-run --unit=t715-sleep-display --collect -E LONG=120 \
#       sh /root/sleep-display.sh 6 20
#
# usage: sh sleep-display.sh [N [SECS]]  N sleeps (10) of SECS seconds (20),
#   every second one LONG seconds instead when LONG is set.
#
# Why: on 2026-11-10 a key wake often left the screen black -- the
# panel's first DSI command timed out ("xfer timed out"), then "vblank
# wait timed out" and "flip_done timed out" until the screen was switched
# off and on again.  Lit a second after the wake, the screen always came
# back; lit at once, 5 wakes in 6 failed.  This script lights it at once:
# the moment /sys/power/suspend_stats/success moves (before the tasks
# thaw, as a key event reaches t715-keys), it sends t715-keys SIGUSR2, the
# glance a key press gives, and t715-keys turns the screen off again by
# itself; SIGUSR1 darkens it before each sleep.  The kernel of the
# t715-sleep series handles the DSI interrupt in hard IRQ context since.
#
# Each sleep goes through the system's own path (systemctl suspend, so
# t715-sleep's prepare and resume run); t715-sleep.service, which would
# suspend by itself while the screen is dark, is stopped meanwhile and
# started again at the end.  One line per sleep in
# /var/log/t715-sleep-soak/disp-*.log and at error level in the kernel
# log: real or not, the wake's WAKEUP_STAT and EINT_PEND words, the
# seconds to DPMS on, and the counts of "xfer timed out", "vblank wait
# timed out", "flip_done timed out" and other DSI errors; plus the CPU
# time of the interrupt threads in the two seconds after the wake.  Never a
# raw kernel line.  Written: the RTC's wakealarm, the log, /dev/kmsg,
# /tmp/disp-*.txt, signals to t715-keys, systemctl stop/start/suspend.
set -u
N=${1:-10}; SECS=${2:-20}
LOG=/var/log/t715-sleep-soak/disp-$(date +%Y%m%d-%H%M%S).log
mkdir -p /var/log/t715-sleep-soak
log() { echo "$(date +%T) $*" >> "$LOG"; ( echo "<3>t715-sleep-display: $*" > /dev/kmsg ) 2>/dev/null; }
dpms() { cat /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -n 1; }
keys() { pgrep -u alarm -f /usr/local/bin/t715-keys | head -n 1; }
ready() {  # restore idle, Wi-Fi up (guard), CP settled; at most 240 s
  w=0
  while [ $w -lt 240 ]; do
    case $(systemctl is-active t715-sleep-restore.service) in active|activating) ;; *)
      if /usr/local/sbin/t715-wifi-guard check >/dev/null 2>&1; then
        case $(t715-modem-power status --json 2>/dev/null | sed -n 's/.*"cp":"\([a-z]*\)".*/\1/p') in
          booting|waiting|stopping) ;; *) return 0 ;;
        esac
      fi ;;
    esac
    sleep 2; w=$((w+2))
  done
  return 1
}
klog_after() {  # kernel log lines after the line stamped $1
  dmesg | grep -v -i 'kernel command line' > /tmp/disp-k.txt
  n=$(grep -n "^\[ *$1\]" /tmp/disp-k.txt | tail -n 1 | cut -d: -f1)
  if [ -n "$n" ]; then sed -n "$((n+1)),\$p" /tmp/disp-k.txt; else cat /tmp/disp-k.txt; fi
  rm -f /tmp/disp-k.txt
}
irq_tids() { for t in /proc/[0-9]*/task/[0-9]*; do c=$(cat "$t/comm" 2>/dev/null) || continue; case $c in (irq/*) echo "${t##*/}" ;; esac; done; }
IRQT=$(irq_tids)
irqrun() {  # "tid comm ns" for every irq/ thread (their tids, listed once)
  for tid in $IRQT; do
    echo "$tid $(cat "/proc/$tid/comm" 2>/dev/null) $(cut -d' ' -f1 "/proc/$tid/schedstat" 2>/dev/null)"
  done
}
POLICY=0
if systemctl -q is-active t715-sleep.service; then
  POLICY=1; systemctl stop t715-sleep.service
fi
# shellcheck disable=SC2317
finish() { echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null; [ "$POLICY" = 1 ] && systemctl start t715-sleep.service; rm -f /tmp/disp-irq0.txt /tmp/disp-irq1.txt; }
trap finish EXIT
trap 'exit 1' TERM INT HUP
pol=inactive; [ "$POLICY" = 1 ] && pol=stopped
log "start: N=$N SECS=$SECS LONG=${LONG:-none}, t715-sleep.service $pol"
bad=0
i=1
while [ $i -le "$N" ]; do
  ready || log "cycle $i: not ready within 240 s (going on)"
  # the screen dark first, as after an idle or a Power press
  if [ "$(dpms)" != Off ]; then kill -USR1 "$(keys)" 2>/dev/null; sleep 3; fi
  [ "$(dpms)" = Off ] || log "cycle $i: the screen did not go dark ($(dpms))"
  mark=$(dmesg | tail -n 1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
  s0=$(cat /sys/power/suspend_stats/success)
  # SECS alternates with LONG on even cycles: a long sleep, as some failures followed
  d=$SECS; [ $((i % 2)) -eq 0 ] && d=${LONG:-$SECS}
  echo 0 > /sys/class/rtc/rtc0/wakealarm; echo "+$d" > /sys/class/rtc/rtc0/wakealarm
  kp=$(keys)
  systemctl suspend --check-inhibitors=no
  # the snapshot once prepare has armed the sleep: the window is the freeze, the sleep,
  # the resume and the 2 s after it, not prepare's own work
  a=0; while [ "$(cat /sys/module/exynos5433_sleep/parameters/arm)" != Y ] && [ $a -lt 1200 ]; do sleep 0.05; a=$((a+1)); done
  irqrun > /tmp/disp-irq0.txt
  # the kernel's success count moves before the tasks thaw: signal t715-keys at once, as
  # a key event reaches it in the same instant after a key wake
  w=0; while [ "$(cat /sys/power/suspend_stats/success)" = "$s0" ] && [ $w -lt $(((d+150)*20)) ]; do sleep 0.05; w=$((w+1)); done
  kill -USR2 "$kp" 2>/dev/null
  t0=$(date +%s)
  on=''; k=0
  while [ $k -lt 40 ]; do [ "$(dpms)" = On ] && { on=$(( $(date +%s) - t0 )); break; }; sleep 0.25; k=$((k+1)); done
  sleep 2
  irqrun > /tmp/disp-irq1.txt
  top=$(while read -r tid comm ns; do
          b=$(grep "^$tid " /tmp/disp-irq0.txt | cut -d' ' -f3); [ -n "$b" ] || b=0
          echo "$(( (ns - b) / 1000000 )) $comm"
        done < /tmp/disp-irq1.txt | sort -rn | head -n 5 | tr '\n' ',')
  log "cycle $i: irq threads' ms in the 2 s after the wake: $top"
  sleep 6
  kt=$(klog_after "$mark")
  real=$(printf '%s\n' "$kt" | grep -c 'EXYNOS5433: SMC_CMD_SLEEP')
  xfer=$(printf '%s\n' "$kt" | grep -c 'xfer timed out')
  vbl=$(printf '%s\n' "$kt" | grep -c 'vblank wait timed out')
  flip=$(printf '%s\n' "$kt" | grep -c 'flip_done timed out')
  dsierr=$(printf '%s\n' "$kt" | grep -i -c 'dsi.*\(error\|fail\|timeout\|timed out\)')
  eint=$(printf '%s\n' "$kt" | sed -n 's/.*woke up: WAKEUP_STAT \(0x[0-9a-f]*\), EINT_PEND \([0-9a-f ]*\),.*/\1 \2/p' | head -n 1)
  [ $((xfer + vbl + flip)) -gt 0 ] && bad=$((bad+1))
  log "cycle $i (${d}s): real=$real wake=[$eint] dpms_on_after=${on:-never}s xfer_timeout=$xfer vblank_timeout=$vbl flip_timeout=$flip dsi_err=$dsierr"
  i=$((i+1))
done
log "summary: $N cycles, $bad with a display timeout"
