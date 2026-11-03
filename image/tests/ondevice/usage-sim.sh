#!/usr/bin/env bash
# usage-sim.sh — simulated use of the tablet's session, for a soak when the
# owner cannot use it (CPUFREQ.md section 9, 1f). Runs as root ON THE TABLET:
#   ssh root@172.16.42.1 'bash -s' -- MINUTES < tests/ondevice/usage-sim.sh
# Cycles of about 9 minutes until MINUTES have passed. While the session is
# unlocked and the screen on:
#   - the touch shell's panels, through uibench.sh if /run/uibench.sh is there;
#   - a 720p H.264 clip in mpv, full screen, 3 minutes;
#   - a long animated page scrolling by itself in Chromium, 2.5 minutes;
#   - 2 minutes with nothing open, the screen on.
# Otherwise nothing goes to the session: a headless cycle (the clip decoded
# by ffmpeg in real time, 3 minutes; then 6 minutes of idle, the screen as
# the owner left it: off, that is the idle measurement).
# It sends no key and types nothing: app launches and the shell's IPC only,
# and never turns the screen off itself (a screen-off locks the session once
# a PIN is set). Before every session step the session must be unlocked and
# the screen on: on a locked session, keys and apps would reach the lock's
# password field. An idle inhibitor is held during the session steps.
set -u
MIN=${1:-100}
RUN=/run/user/1000
SESSION_LANG=$(sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null)
au() { runuser -u alarm -- env LANG=${SESSION_LANG:-C.UTF-8} XDG_RUNTIME_DIR=$RUN HYPRLAND_INSTANCE_SIGNATURE="$(ls -t $RUN/hypr | head -1)" WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS=unix:path=$RUN/bus OMARCHY_PATH=/usr/share/omarchy "$@"; }
say() { echo "sim: $(date +%T) $*"; }
dpms() { cat /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1; }
unlocked() { [ "$(au omarchy-shell lock isLocked 2>/dev/null | tail -1)" = false ]; }
usable() { unlocked && [ "$(dpms)" = On ]; } # the rule, before anything goes to the session
inh=""
inhibit_on() { [ -n "$inh" ] && return; au systemd-inhibit --what=idle --who=t715-usage-sim --why="simulated use" sleep 3600 & inh=$!; }
inhibit_off() { [ -n "$inh" ] && kill "$inh" 2>/dev/null; inh=""; }
cleanup() { inhibit_off; pkill -u alarm -f -- "$D/clip.mp4" 2>/dev/null; pkill -u alarm -f -- "--user-data-dir=$D/chromium" 2>/dev/null; true; }
trap 'cleanup' EXIT
trap 'exit 130' INT TERM HUP

D=/tmp/t715-soak; mkdir -p $D; chown alarm: $D
if [ ! -s $D/clip.mp4 ]; then
    say "making the clip"
    ffmpeg -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 60 -c:v libx264 -preset veryfast -pix_fmt yuv420p $D/clip.mp4 </dev/null && chown alarm: $D/clip.mp4
fi
cat > $D/page.html <<'EOF'
<!doctype html><meta charset=utf-8><title>t715 soak</title>
<style>body{font:18px sans-serif;margin:0}.c{height:240px;margin:12px;border-radius:16px;
background:linear-gradient(90deg,#c33,#36c,#3a6);background-size:300% 100%;animation:m 3s linear infinite}
@keyframes m{to{background-position:300% 0}}p{margin:12px}</style>
<script>addEventListener("load",()=>{let y=0,d=4;setInterval(()=>{y+=d;if(y>document.body.scrollHeight-innerHeight||y<0)d=-d;scrollTo(0,y)},16)});
document.write(Array.from({length:120},(_,i)=>`<div class=c></div><p>${"Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(6)} ${i}</p>`).join(""))</script>
EOF
chown alarm: $D/page.html

end=$(( $(date +%s) + MIN * 60 )); n=0
headless() {
    # One decode at the clip's own rate (-re), as a player would: one or two
    # cores' worth. Not as fast as possible on all eight: on 2026-11-03 that
    # took atlas1 to 99 C in 90 s, the A57s having no level to give back.
    say "headless: the clip decoded in real time, then idle (screen $(dpms))"
    timeout 180 nice -n 10 ffmpeg -v error -re -stream_loop -1 -i $D/clip.mp4 -f null - </dev/null
    sleep 360
}
end=$(( $(date +%s) + MIN * 60 )); n=0; g=0
while [ "$(date +%s)" -lt "$end" ]; do
    n=$((n + 1))
    if ! usable; then inhibit_off; headless; continue; fi
    g=$((g + 1)); say "cycle $n, in the session"; inhibit_on
    if [ -r /run/uibench.sh ]; then say "panels"; bash /run/uibench.sh "soak$n" </dev/null >/dev/null 2>&1; fi
    usable || continue
    say "video"; au hyprctl dispatch exec "mpv --loop --fs --no-terminal $D/clip.mp4" >/dev/null
    sleep 180; pkill -u alarm -f -- "$D/clip.mp4"; sleep 3
    usable || continue
    # A profile of its own: the owner's Chromium, if open, is never touched
    say "browser"; au hyprctl dispatch exec "chromium --user-data-dir=$D/chromium --no-first-run file://$D/page.html" >/dev/null
    sleep 150
    pkill -u alarm -f -- "--user-data-dir=$D/chromium"; sleep 5
    say "idle, screen on"; sleep 120
done
say "done, $n cycles, $g in the session"
