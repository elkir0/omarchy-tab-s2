#!/bin/bash
# smoke-check — "does the image hold together" check of the SM-T715 arm64
# images (run at the end of the build, in the image's own container: no
# hardware, no watchdog, no compositor), installed as
# /usr/lib/t715-arm64/smoke-check. It starts nothing and writes only to a
# temporary directory. Adapted from omarchy-tab-s2/image/rootfs/
# smoke-check.sh.
#
# FAIL (exit 1): systemd, sshd, NetworkManager or sudo cannot report a
#                version; sshd's configuration does not parse; the boot mark
#                and the watchdog keeper are not in place or do not behave
#                (the mark's exact line, the keeper feeds a running watchdog
#                and never starts a stopped one); the units are not enabled
#                or do not pass systemd-analyze verify; the bring-up knobs
#                (t715.kbootmark=0, t715.return=MIN) are not in place or do
#                not behave; root is not locked or the user is not as
#                documented (alarm, uid 1000, not ALARM's password); the SSH
#                key is not installed for both root and the user, or sshd
#                would take a password; a kernel, modules
#                or host keys shipped; the Wi-Fi firmware is not the pinned
#                one; the Omarchy session binaries (when omarchy is
#                installed) cannot run or miss a library.
# WARN/INFO (never fail): what depends on the tablet (vendor files, the
#                compositor itself, QML modules the shell may miss).
set -u

fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 0755 "$tmp"
U="$(sed -n 's/^T715_USER=//p' /usr/share/t715-arm64/user.env 2>/dev/null)"
[ -n "$U" ] || fail "no user name in /usr/share/t715-arm64/user.env"
mkdir -p "$tmp/home" "$tmp/run"
chmod 0700 "$tmp/run"
# The session's binaries run as the user, not as root (Hyprland refuses to).
runas=()
if [ "$(id -u)" = 0 ] && id "$U" >/dev/null 2>&1; then
    chown "$U:$U" "$tmp/home" "$tmp/run"
    runas=(runuser -u "$U" --)
fi
run() {
    timeout 180 "${runas[@]}" env -i PATH=/usr/local/bin:/usr/bin \
        HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" LANG=C.UTF-8 \
        QT_QPA_PLATFORM=offscreen "$@"
}

echo "== versions =="
version() {
    local label="$1" out rc
    shift
    out="$(run "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        pass "$label: $(printf '%s\n' "$out" | head -n1 | cut -c1-110)"
    else
        fail "$label (exit $rc): $(printf '%s\n' "$out" | head -n1 | cut -c1-160)"
    fi
}
version "systemctl --version" systemctl --version
version "NetworkManager --version" NetworkManager --version
version "sudo --version" sudo --version
version "busybox" sh -c 'busybox 2>&1 | sed -n "1p"'
version "python3" python3 --version
info "packages installed: $(pacman -Q | wc -l), explicit: $(pacman -Qe | wc -l); architecture $(uname -m)"

echo "== systemd units =="
# Every unit of ours: it parses and what it needs exists.
unit_dir=/etc/systemd/system
units="$(ls "$unit_dir"/t715-*.service "$unit_dir"/usb-rndis.service 2>/dev/null)"
if [ -n "$units" ] && out="$(run systemd-analyze verify $units 2>&1)"; then
    pass "systemd-analyze verify: $(printf '%s\n' "$units" | xargs -n1 basename | tr '\n' ' ')"
else
    fail "systemd-analyze verify: $(printf '%s\n' "${out:-no unit}" | grep -v '^$' | head -n3 | tr '\n' ' ' | cut -c1-300)"
fi
enabled_ok=1
for unit in sshd.service NetworkManager.service usb-rndis.service \
            t715-kboot-mark.service t715-watchdog-keeper.service t715-vendor-firmware.service \
            run-t715-userdata.mount; do
    if [ "$(run systemctl is-enabled "$unit" 2>/dev/null)" = enabled ]; then
        pass "$unit is enabled"
    else
        fail "$unit is not enabled"; enabled_ok=0
    fi
done
for target in suspend sleep hibernate hybrid-sleep suspend-then-hibernate; do
    # The Omarchy image unmasks suspend and sleep for t715-sleep: its part of
    # the check (smoke-check-omarchy, "Sleep") checks them.
    case "$target" in
        suspend|sleep) pacman -Q omarchy >/dev/null 2>&1 && continue ;;
    esac
    [ "$(readlink "/etc/systemd/system/$target.target" 2>/dev/null)" = /dev/null ] \
        && pass "$target.target is masked" || fail "$target.target is not masked"
done
want_target=multi-user.target
pacman -Q omarchy >/dev/null 2>&1 && want_target=graphical.target
[ "$(readlink /etc/systemd/system/default.target)" = "/usr/lib/systemd/system/$want_target" ] \
    && pass "default target: $want_target" || fail "default target is $(readlink /etc/systemd/system/default.target), not $want_target"
# PID 1 must not feed the watchdog itself: the kernel never does, the keeper does.
# 0 is systemd's default: no active line, or active lines that all say 0.
if ! grep -hE '^\s*RuntimeWatchdogSec\s*=' /etc/systemd/system.conf /etc/systemd/system.conf.d/*.conf 2>/dev/null \
        | grep -qvE '^\s*RuntimeWatchdogSec\s*=\s*0\b'; then
    pass "systemd's RuntimeWatchdogSec is 0 (only t715-watchdog-keeper feeds the watchdog)"
else
    fail "RuntimeWatchdogSec is not 0 in /etc/systemd/system.conf"
fi
# systemd expands a lone %d in a unit to the credentials directory: a printf-style
# "%d" meant for a program must be written "%%d" (t715-keys crashed at every
# screen-off for want of it, 2026-11-25).
lone_pct_d="$(grep -HnE '^[^#;%]([^%]|%%)*%d' /etc/systemd/system/t715-*.service /etc/systemd/user/t715-*.service 2>/dev/null)"
if [ -z "$lone_pct_d" ]; then
    pass "no lone %d specifier in the t715 units"
else
    fail "a lone %d in a t715 unit (systemd expands it): $lone_pct_d"
fi
# The modem's modules never load by themselves: spi_s3c64xx would set the SPI4
# pins at every boot with the modem unpowered (2026-11-25).
missing_bl=""
for m in exynos5433_mipi_lli sec_modem_v1 spi_s3c64xx; do
    grep -qx "blacklist $m" /etc/modprobe.d/t715-modem.conf 2>/dev/null || missing_bl="$missing_bl $m"
done
if [ -z "$missing_bl" ]; then
    pass "the modem modules are blacklisted (/etc/modprobe.d/t715-modem.conf)"
else
    fail "modem modules not blacklisted:$missing_bl"
fi

keeper=/usr/local/sbin/t715-watchdog-keeper   # also set below, where its own checks start
if [ -x "$keeper" ] && out="$(run "$keeper" --check 2>&1)" && printf '%s\n' "$out" | grep -q 'ok'; then
    pass "t715-watchdog-keeper --check runs (the boot mark unit's ExecStartPre)"
else
    fail "t715-watchdog-keeper --check does not run: $out"
fi
grep -q '^ConditionPathExists=/dev/watchdog$' "$unit_dir/t715-kboot-mark.service" \
    && pass "the boot mark is conditioned on the watchdog device (no device: no mark, the loader falls back)" \
    || fail "t715-kboot-mark.service has no ConditionPathExists=/dev/watchdog"

echo "== the bring-up knobs: t715.kbootmark=0 and t715.return=MIN =="
mk="$unit_dir/t715-kboot-mark.service"
grep -qx 'ConditionKernelCommandLine=!t715.kbootmark=0' "$mk" \
    && pass "t715.kbootmark=0 keeps the mark from running (ConditionKernelCommandLine=!t715.kbootmark=0)" \
    || fail "t715-kboot-mark.service has no ConditionKernelCommandLine=!t715.kbootmark=0"
req="$(sed -n 's/^Requires=//p' "$mk" | tr ' ' '\n')"
aft="$(sed -n 's/^After=//p' "$mk" | tr ' ' '\n')"
ok=1
for u in sshd.service usb-rndis.service t715-watchdog-keeper.service; do
    printf '%s\n' "$req" | grep -qx "$u" || ok=0
    printf '%s\n' "$aft" | grep -qx "$u" || ok=0
done
[ "$ok" = 1 ] && pass "the mark requires and follows sshd.service, usb-rndis.service and the keeper (the owner can reach the system first)" \
    || fail "t715-kboot-mark.service does not require and follow sshd, usb-rndis and the keeper: Requires=$(echo $req) After=$(echo $aft)"
if grep -qE '^(Before=.*basic\.target|DefaultDependencies=no)' "$mk"; then
    fail "t715-kboot-mark.service is still ordered before basic.target (a cycle with sshd.service)"
else
    pass "the mark has the default dependencies and no Before=basic.target (no ordering cycle with sshd)"
fi
[ -L /etc/systemd/system/multi-user.target.wants/t715-kboot-mark.service ] \
    && pass "the mark is wanted by multi-user.target" || fail "t715-kboot-mark.service is not in multi-user.target.wants"
kp="$unit_dir/t715-watchdog-keeper.service"
if grep -E '^(Requires|After|BindsTo|Wants)=' "$kp" | grep -q 't715-kboot-mark'; then
    fail "the keeper still waits for the mark (it must start before basic.target)"
else
    grep -q '^Before=basic.target$' "$kp" && pass "the keeper starts early, before basic.target, without waiting for the mark" \
        || fail "t715-watchdog-keeper.service is not Before=basic.target"
fi
gen=/etc/systemd/system-generators/t715-return-generator
rt="$unit_dir/t715-return.timer"; rs="$unit_dir/t715-return.service"
if [ -x "$gen" ] && sh -n "$gen" && [ -f "$rt" ] && [ -f "$rs" ] && [ -x /usr/local/sbin/t715-return ] && sh -n /usr/local/sbin/t715-return; then
    pass "t715.return: the generator, t715-return.timer, t715-return.service and /usr/local/sbin/t715-return are in place and parse"
else
    fail "t715.return: the generator, the timer, the service or the script is missing or does not parse"
fi
if out="$(run systemd-analyze verify "$rt" "$rs" 2>&1)"; then
    pass "systemd-analyze verify: t715-return.timer t715-return.service"
else
    fail "systemd-analyze verify of t715-return.*: $(printf '%s\n' "$out" | grep -v '^$' | head -n3 | tr '\n' ' ' | cut -c1-300)"
fi
grep -qx 'ConditionKernelCommandLine=t715.return' "$rt" && grep -qx 'ConditionKernelCommandLine=t715.return' "$rs" \
    && pass "the timer and the service run only with t715.return on the command line" \
    || fail "t715-return.timer or .service lacks ConditionKernelCommandLine=t715.return"
if ls /etc/systemd/system/*.wants/t715-return.* >/dev/null 2>&1; then
    fail "t715-return.timer is enabled in the image (only its generator may enable it, with the knob)"
else
    pass "t715-return.timer is not enabled in the image: without the knob nothing happens"
fi
gen_case() { # NAME CMDLINE: the generator's output tree in $tmp/gen-NAME
    printf '%s\n' "$2" > "$tmp/cmdline-$1"
    T715_CMDLINE="$tmp/cmdline-$1" T715_KMSG="$tmp/kmsg-$1" sh "$gen" "$tmp/gen-$1"
}
gen_case none 'console=tty1 t715.persist=omarchy-arm64 t715.kbootmark=0'
gen_case seven 'console=tty1 t715.kbootmark=0 t715.return=7'
gen_case bad 'console=tty1 t715.return=soon'
if [ ! -e "$tmp/gen-none" ]; then pass "generator, no t715.return: writes nothing"
else fail "generator, no t715.return: wrote $(find "$tmp/gen-none" | tr '\n' ' ')"; fi
if [ "$(readlink "$tmp/gen-seven/timers.target.wants/t715-return.timer")" = "$rt" ] \
   && grep -qx 'OnBootSec=7min' "$tmp/gen-seven/t715-return.timer.d/50-t715-return-cmdline.conf" \
   && grep -qx 'OnBootSec=' "$tmp/gen-seven/t715-return.timer.d/50-t715-return-cmdline.conf"; then
    pass "generator, t715.return=7: the timer enabled (timers.target.wants), OnBootSec reset to 7min"
else
    fail "generator, t715.return=7: $(find "$tmp/gen-seven" 2>/dev/null | tr '\n' ' ')"
fi
if [ -L "$tmp/gen-bad/timers.target.wants/t715-return.timer" ] && [ ! -e "$tmp/gen-bad/t715-return.timer.d" ] \
   && grep -q 'not 1 to 1440' "$tmp/kmsg-bad"; then
    pass "generator, t715.return=soon: the timer enabled with its own 10 min (fail safe), said in the kernel log"
else
    fail "generator, t715.return=soon: $(find "$tmp/gen-bad" 2>/dev/null | tr '\n' ' ')"
fi
grep -qx 'OnBootSec=10min' "$rt" && pass "the timer's own OnBootSec is 10min" || fail "t715-return.timer has no OnBootSec=10min"
: > "$tmp/stay"
out="$(T715_STAY="$tmp/stay" T715_KMSG="$tmp/kmsg-r1" T715_REBOOT="echo REBOOT" sh /usr/local/sbin/t715-return 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q REBOOT && grep -q 'this boot stays' "$tmp/kmsg-r1"; then
    pass "t715-return with /run/t715-stay: no reboot, said in the kernel log"
else
    fail "t715-return with the stay file: exit $rc, $out"
fi
out="$(T715_STAY="$tmp/no-stay" T715_KMSG="$tmp/kmsg-r2" T715_REBOOT="echo REBOOT" sh /usr/local/sbin/t715-return 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx REBOOT && grep -q 'rebooting' "$tmp/kmsg-r2"; then
    pass "t715-return without /run/t715-stay: systemctl reboot (stubbed here), said in the kernel log"
else
    fail "t715-return without the stay file: exit $rc, $out"
fi
grep -q '^ExecStart=/usr/local/sbin/t715-return$' "$rs" && ! grep -q 'T715_REBOOT' "$rs" \
    && pass "the service runs t715-return as shipped (systemctl reboot)" || fail "t715-return.service does not run /usr/local/sbin/t715-return as is"

echo "== the boot mark (t715-kboot-mark) =="
mark=/usr/local/sbin/t715-kboot-mark
if [ -x "$mark" ] && sh -n "$mark" && "$mark" "$tmp/kmsg" && [ "$(cat "$tmp/kmsg")" = '<3>KBOOT: up' ] \
   && [ "$(wc -c < "$tmp/kmsg")" -eq 13 ]; then
    pass "t715-kboot-mark writes exactly '<3>KBOOT: up' and a newline (13 bytes)"
else
    fail "t715-kboot-mark is missing, does not parse, or does not write '<3>KBOOT: up'"
fi

echo "== the watchdog keeper (t715-watchdog-keeper) =="
keeper=/usr/local/sbin/t715-watchdog-keeper
if [ -x "$keeper" ] && out="$(readelf -h "$keeper" 2>&1)" \
   && printf '%s\n' "$out" | grep -q 'Machine: *AArch64' && printf '%s\n' "$out" | grep -q 'Type: *EXEC'; then
    pass "t715-watchdog-keeper is an AArch64 executable"
else
    fail "t715-watchdog-keeper is missing or not an AArch64 executable"
fi
if readelf -l "$keeper" 2>/dev/null | grep -q 'Requesting program interpreter'; then
    fail "t715-watchdog-keeper is dynamic (it must not depend on a shared library)"
else
    pass "t715-watchdog-keeper is static"
fi
# The kernel's decision is s3c2410_wdt.tmr_atboot on its command line (a stand-in file here).
# Not armed (no word, a 0, or a later 0): the keeper must not touch the device.
for line in 'console=tty0 panic=10' 'console=tty0 s3c2410_wdt.tmr_atboot=0' 's3c2410-wdt.tmr-atboot=1 x s3c2410_wdt.tmr_atboot=0'; do
    printf '%s\n' "$line" > "$tmp/cmdline"
    rm -f "$tmp/never-opened"
    out="$(run "$keeper" --device "$tmp/never-opened" --cmdline "$tmp/cmdline" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -e "$tmp/never-opened" ] && printf '%s\n' "$out" | grep -q 'left the watchdog stopped' && ! printf '%s\n' "$out" | grep -q 'console='; then
        pass "a watchdog the kernel did not arm ('$line'): the keeper starts nothing, prints no command line, exits 0"
    else
        fail "a watchdog the kernel did not arm ('$line'): exit $rc, $(printf '%s\n' "$out" | head -n1)"
    fi
done
# A running watchdog, a FIFO standing in for the device: a ping every
# --interval seconds, nothing but pings; SIGTERM: prompt exit, no magic close.
printf 'console=sec_log s3c2410-wdt.tmr_atboot=1 loglevel=7\n' > "$tmp/cmdline"
mkfifo "$tmp/wdt"
( cat "$tmp/wdt" > "$tmp/pings" ) & reader=$!
sleep 0.2
"$keeper" --device "$tmp/wdt" --cmdline "$tmp/cmdline" --interval 1 > "$tmp/keeper.log" 2>&1 & keeper_pid=$!
sleep 2.5
kill -TERM "$keeper_pid" 2>/dev/null
wait "$keeper_pid"; rc=$?
wait "$reader" 2>/dev/null
pings="$(cat "$tmp/pings" 2>/dev/null | tr -d '\n')"
if [ "$rc" -eq 0 ] && [ "${#pings}" -ge 2 ] && [ "${#pings}" -le 3 ] && [ "$(printf '%s' "$pings" | tr -d '.' | wc -c | tr -d ' ')" -eq 0 ]; then
    pass "a running watchdog: ${#pings} keeper ping(s) in 2.5 s at --interval 1, then SIGTERM: exit 0, watchdog left running"
else
    fail "a running watchdog: exit $rc, pings='${pings}' (expected 2 or 3 dots); log: $(head -n2 "$tmp/keeper.log" | tr '\n' ' ')"
fi
# SIGUSR1 disarms: exactly one magic close.
mkfifo "$tmp/wdt2"
( cat "$tmp/wdt2" > "$tmp/pings2" ) & reader=$!
sleep 0.2
"$keeper" --device "$tmp/wdt2" --cmdline "$tmp/cmdline" --interval 1 > "$tmp/keeper2.log" 2>&1 & keeper_pid=$!
sleep 0.8
kill -USR1 "$keeper_pid" 2>/dev/null
wait "$keeper_pid"; rc=$?
wait "$reader" 2>/dev/null
if [ "$rc" -eq 0 ] && [ "$(tail -c 1 "$tmp/pings2" 2>/dev/null)" = V ] && [ "$(grep -c magic "$tmp/keeper2.log")" -eq 1 ]; then
    pass "SIGUSR1: the keeper writes the magic close and exits 0"
else
    fail "SIGUSR1: exit $rc, last byte '$(tail -c 1 "$tmp/pings2" 2>/dev/null)'"
fi
info "the kernel's behaviour around the keeper (magic close, nowayout, the kernel's own ping) cannot be checked in a container"

echo "== accounts =="
if [ "$(awk -F: '$1 == "root" { print $2 }' /etc/shadow)" = '!' ]; then
    pass "root is locked"
else
    fail "root is not locked"
fi
if id "$U" >/dev/null 2>&1 && [ "$(id -u "$U")" = 1000 ] && id -nG "$U" | grep -qw wheel && [ "$(stat -c %U:%G "/home/$U")" = "$U:$U" ]; then
    pass "the user $U: uid 1000, in wheel, owns /home/$U"
else
    fail "the user $U is not as documented (uid 1000, in wheel, owns /home/$U)"
fi
[ "$U" = alarm ] && pass "the user is alarm, as on the owner's armv7h tablet" || warn "the user is $U, not alarm (build.sh --user)"
uhash="$(awk -F: -v u="$U" '$1 == u { print $2 }' /etc/shadow)"
usalt="$(printf '%s\n' "$uhash" | cut -d'$' -f3)"
if [ -z "$uhash" ] || [ "$uhash" = '!' ] || [ "$uhash" = '*' ]; then
    fail "$U has no password (the lock screen and sudo need one)"
elif [ "$uhash" = "$(openssl passwd -6 -salt "$usalt" alarm 2>/dev/null)" ]; then
    fail "$U still has ALARM's documented password (alarm)"
elif [ "$uhash" = "$(openssl passwd -6 -salt t715placeholder changeme 2>/dev/null)" ]; then
    pass "$U's password is the build's documented placeholder (changeme): not ALARM's alarm"
else
    pass "$U's password is the hash given at the build: not ALARM's alarm"
fi
if visudo -c >/dev/null 2>&1; then pass "sudoers parse (visudo -c)"; else fail "visudo -c fails"; fi
if run sudo -l -U "$U" 2>/dev/null | grep -q 'NOPASSWD: ALL'; then pass "sudo: $U may do everything without a password"; else fail "sudo: $U is not NOPASSWD"; fi

echo "== ssh =="
if [ -e /etc/ssh/ssh_host_ed25519_key ] || ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    fail "SSH host keys are in the image (every tablet would share them)"
else
    pass "no SSH host keys in the image (sshd makes them at its first start)"
fi
ssh-keygen -q -t ed25519 -N '' -C smoke -f "$tmp/host" 2>/dev/null
if out="$(/usr/sbin/sshd -t -h "$tmp/host" 2>&1)"; then
    pass "sshd -t: the configuration parses"
else
    fail "sshd -t (exit $?): $(printf '%s\n' "$out" | head -n2 | tr '\n' ' ')"
fi
sshd_t="$(/usr/sbin/sshd -T -h "$tmp/host" 2>/dev/null)"
# (OpenSSH 10 prints the keywords in their own case, older ones in lower case.)
if printf '%s\n' "$sshd_t" | grep -qix 'passwordauthentication no' \
   && printf '%s\n' "$sshd_t" | grep -qix 'kbdinteractiveauthentication no' \
   && printf '%s\n' "$sshd_t" | grep -qix 'permitrootlogin without-password\|permitrootlogin prohibit-password'; then
    pass "sshd -T: no password over ssh (PasswordAuthentication and KbdInteractiveAuthentication no), root by key only ($(printf '%s\n' "$sshd_t" | grep -i '^permitrootlogin'))"
else
    fail "sshd -T: $(printf '%s\n' "$sshd_t" | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) ' | tr '\n' ' ')"
fi
rk=/root/.ssh/authorized_keys; uk="/home/$U/.ssh/authorized_keys"
if [ -s "$rk" ] || [ -s "$uk" ]; then
    if [ -s "$rk" ] && [ -s "$uk" ] && cmp -s "$rk" "$uk" \
       && [ "$(stat -c '%a %U' /root/.ssh "$rk")" = "$(printf '700 root\n600 root')" ] \
       && [ "$(stat -c '%a %U' "/home/$U/.ssh" "$uk")" = "$(printf '700 %s\n600 %s' "$U" "$U")" ] \
       && grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9-]+@openssh\.com) ' "$rk"; then
        pass "the SSH key given at the build is installed for root and $U ($(grep -c . "$rk") line(s); 0700/0600, their own)"
    else
        fail "the SSH key is not installed the same for root and $U (both files, 0700/0600, owned by each)"
    fi
else
    warn "no SSH key: nobody can log in over ssh until one is given (build.sh --ssh-pubkey FILE)"
fi

echo "== no kernel, no modules =="
kernel="$(pacman -Qq | grep -E '^linux' | grep -vx 'linux-api-headers' || true)"
[ -z "$kernel" ] && pass "no kernel or firmware package" || fail "kernel or firmware packages installed: $(echo $kernel)"
[ ! -e /usr/lib/modules ] && pass "no /usr/lib/modules" || fail "/usr/lib/modules is in the tree"
[ -z "$(ls -A /boot 2>/dev/null)" ] && pass "/boot is empty" || fail "/boot is not empty: $(ls -A /boot | tr '\n' ' ')"
[ -x /sbin/init ] && [ "$(readlink -f /sbin/init)" = /usr/lib/systemd/systemd ] \
    && pass "/sbin/init is systemd" || fail "/sbin/init is not systemd ($(readlink -f /sbin/init 2>/dev/null))"

echo "== scripts and binaries load =="
bad=""
for f in /usr/local/sbin/usb-rndis-setup /usr/local/sbin/t715-wifi-addr /usr/local/sbin/t715-vendor-firmware \
         /usr/local/sbin/t715-wifi-guard /usr/local/sbin/t715-sleep \
         /usr/lib/systemd/system-shutdown/t715-stuck-procs /usr/local/bin/t715-pstore-shutdown; do
    [ -f "$f" ] || { bad="$bad $f(missing)"; continue; }
    bash -n "$f" 2>/dev/null || bad="$bad $f"
done
[ -z "$bad" ] && pass "the overlay's shell scripts parse" || fail "overlay scripts:$bad"
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' /usr/local/sbin/t715-reboot-to 2>/dev/null \
    && pass "t715-reboot-to parses" || fail "t715-reboot-to does not parse"
missing="$(ldd /usr/bin/NetworkManager 2>&1 /usr/bin/sudo /usr/sbin/sshd 2>/dev/null | awk '/not found/ {print $1}' | sort -u | tr '\n' ' ')"
[ -z "$missing" ] && pass "ldd: NetworkManager, sudo, sshd miss no library" || fail "ldd: not found: $missing"

echo "== network =="
nmconf="$(run NetworkManager --print-config 2>/dev/null)"
unmanaged="$(printf '%s\n' "$nmconf" | sed -n 's/^unmanaged-devices=//p' | tail -n1)"
mac="$(printf '%s\n' "$nmconf" | awk '/^\[/ {s = $0} s == "[connection-t715-wifi]" && /^wifi\.cloned-mac-address=/ {print}')"
if printf '%s\n' "$unmanaged" | grep -q 'interface-name:usb0' && printf '%s\n' "$unmanaged" | grep -q 'interface-name:rndis0' \
   && [ "$mac" = 'wifi.cloned-mac-address=preserve' ]; then
    pass "NetworkManager --print-config: USB link unmanaged ($unmanaged), [connection-t715-wifi] $mac"
else
    fail "NetworkManager --print-config: unmanaged='${unmanaged:-none}', [connection-t715-wifi] '${mac:-none}'"
fi

echo "== Wi-Fi and Bluetooth files =="
fw=/usr/lib/firmware/brcm
sha="$(sha256sum "$fw/brcmfmac4358-pcie.bin" 2>/dev/null | cut -d' ' -f1)"
if [ "$sha" = f04d8fdc0a0a301ccbbf543a2b470108c64ee341360f3450ed4fa9bbee04337c ]; then
    pass "brcmfmac4358-pcie.bin: the pinned firmware (sha256 ok)"
else
    fail "brcmfmac4358-pcie.bin is missing or is not the pinned file"
fi
[ "$(readlink "$fw/brcmfmac4358-pcie.txt")" = samsung-gts28/nvram_net.txt ] \
    && pass "brcm/brcmfmac4358-pcie.txt -> samsung-gts28/nvram_net.txt" || fail "no brcmfmac4358-pcie.txt link"
[ "$(readlink "$fw/BCM.samsung,gts28ltexx.hcd")" = BCM4358A3.hcd ] \
    && pass "brcm/BCM.samsung,gts28ltexx.hcd -> BCM4358A3.hcd" || fail "no BCM.samsung,gts28ltexx.hcd link"
if [ -f /usr/share/t715-arm64/VENDOR-FILES-MISSING ]; then
    warn "$(sed -n '2,3p' /usr/share/t715-arm64/VENDOR-FILES-MISSING | sed 's/# *//; s/PLACEHOLDER: //' | tr '\n' ' ' | cut -c1-230)(the vendor files' placeholders)"
else
    pass "the two vendor files were staged by the owner (sizes: NVRAM $(wc -c < "$fw/samsung-gts28/nvram_net.txt"), patch RAM $(wc -c < "$fw/BCM4358A3.hcd") bytes)"
fi

echo "== identifiers (MAC and key patterns in the image's own configuration) =="
# Not every file of /etc (a stock dnsmasq.conf documents example addresses):
# the directories this image's build writes, and NetworkManager's saved
# connections, which an image must never ship (they hold Wi-Fi credentials).
hits="$(grep -rnIE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}|BEGIN [A-Z ]*PRIVATE KEY|ssh-(rsa|ed25519) AAAA|psk=-?' \
        /etc/systemd /etc/systemd/system /etc/NetworkManager /etc/udev /etc/ufw /etc/usb-rndis /etc/ssh/sshd_config.d \
        /etc/sudoers.d /etc/sysctl.d /etc/modprobe.d /etc/hosts /etc/hostname /usr/local /root "/home/$U" \
        --exclude-dir=nvim --exclude=authorized_keys 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' | head -n5)"   # not comment lines: a stock file documents examples
if [ -n "$hits" ]; then warn "review: $(printf '%s' "$hits" | cut -c1-200)"; else pass "none in the image's own configuration, /usr/local, /root, /home/$U"; fi
[ -d /etc/NetworkManager/system-connections ] && [ -n "$(ls -A /etc/NetworkManager/system-connections)" ] \
    && fail "NetworkManager connections are in the image" || pass "no saved NetworkManager connection in the image"

echo "== Omarchy =="
if pacman -Q omarchy >/dev/null 2>&1; then
    . /usr/lib/t715-arm64/smoke-check-omarchy
else
    info "omarchy is not installed (the base image)"
fi

echo "-----"
if [ "$fails" -eq 0 ]; then
    echo "SMOKE: PASS"
    exit 0
fi
echo "SMOKE: FAIL ($fails)"
exit 1
