#!/bin/bash
# omarchy-user-setup.sh — Omarchy's user setup for alarm at build time, then
# the tablet's per-user settings (root, called by configure-system.sh).
#
# 1. omarchy-provision-user --force --first-install, as alarm, the way
#    Omarchy's ISO runs it in the target chroot: no graphical session, but a
#    private D-Bus session bus (dbus-run-session) so that gsettings writes
#    reach dconf. OMARCHY_INSTALL (which omarchy-provision-user honours)
#    points at a build-time copy of install/ whose user/all.sh runs the
#    same, unmodified leaves with Omarchy's run_logged, minus the leaves in
#    SKIP, and records each leaf's result instead of letting the first
#    failure abort the whole user setup.
# 2. omarchy-provision-user ends by making chromium.desktop the default
#    browser; armv7h has no Chromium, so that step fails and the script stops
#    before its last steps. When that happens after every leaf ran, the
#    remaining steps run here, each recorded: application refresh, mailto
#    handler, migration markers (first install), finalize-user marker.
# 3. Firefox (if installed) as the default browser, with what Omarchy's
#    omarchy-install-browser firefox sets up (policy directory, Wayland env).
# 4. Tablet settings: monitor scale 2 (1536x2048 -> 768x1024 logical),
#    AQ_DRM_DEVICES in ~/.config/uwsm/env, the tablet block of
#    ~/.config/hypr/looknfeel.lua (rootfs/t715-looknfeel.lua), Omarchy's
#    "suspend-off" toggle (no Suspend entry in the system menu). Omarchy's
#    idle cycle is off through the tablet profile's shell.json, and its
#    stay-awake state starts off: the Stay awake tile is the owner's to set.
#    Touch layer P1: the tablet block at the end of ~/.config/hypr/hyprland.lua
#    (rootfs/t715-tablet.lua: keys, cover, on-screen keyboard layers, window
#    sizes), the on-screen keyboard's gsettings (shown at all, the layout of
#    locale.env first; through a private D-Bus session, as in step 1), squeekboard's
#    terminal layouts with Esc, auto-rotation on, and no Lock entry in the
#    system menu (nothing could unlock it without a keyboard).
# 5. Touch layer P2 (omamobile-shell): omamobile-setup-user as alarm, with
#    the markers of its phone-only or P1-duplicate steps set first so that
#    they are skipped (each recorded with its reason); its profile step seeds
#    the tablet shell.json; then the tablet home.json, and Omarchy's web apps
#    hidden (they need Chromium).
#
# Usage: omarchy-user-setup.sh OUT.tsv      (step<TAB>status<TAB>detail)
set -uo pipefail

OUT="${1:?usage: omarchy-user-setup.sh OUT.tsv}"
U=alarm
H="$(getent passwd "$U" | cut -d: -f6)"
UID_U="$(id -u "$U")"
OMARCHY_PATH=/usr/share/omarchy
ADAPTED=/tmp/t715-omarchy-install
RUNDIR="/run/user/$UID_U"
LOG=/var/log/t715-omarchy-provision-user.log
# T715_LANG and T715_XKB, as tools/build-rootfs wrote them.
. /usr/share/t715-omarchy/locale.env

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; }

# step NAME DETAIL CMD...: run CMD, record ok/failed.
step() {
    local name="$1" detail="$2" rc
    shift 2
    if "$@" >> "$LOG" 2>&1; then
        record "$name" ok "$detail"
    else
        rc=$?
        record "$name" "failed (exit $rc)" "${detail:+$detail; }see $LOG"
    fi
}

as_user() {
    runuser -u "$U" -- env -i \
        HOME="$H" USER="$U" LOGNAME="$U" SHELL=/bin/bash \
        PATH="$OMARCHY_PATH/bin:/usr/local/bin:/usr/bin" \
        LANG="$T715_LANG" XDG_RUNTIME_DIR="$RUNDIR" \
        OMARCHY_PATH="$OMARCHY_PATH" OMARCHY_INSTALL="$ADAPTED" \
        OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log \
        OMARCHY_USER_NAME= OMARCHY_USER_EMAIL= \
        "$@"
}

x86() { printf 'x86 laptop quirk (%s); the SM-T715 has none of this hardware' "$1"; }
declare -A SKIP=(
    [user/chromium.sh]="sets up Chromium's native messaging helpers, for the extensions of a Chromium the image does not ship: its Chromium is Debian's, in a root of its own"
    [user/mise-work.sh]="installs Node.js through mise, neither available for armv7h (its ~/Work and ~/Work/tries directories are created below)"
    [user/mise.sh]="installs AI and developer CLIs through mise from the network; mise is not available for armv7h"
    [user/hardware/asus/fix-audio-mixer.sh]="$(x86 "ASUS audio mixer")"
    [user/hardware/asus/fix-mic.sh]="$(x86 "ASUS ROG microphone gain")"
    [user/hardware/framework/fix-f13-amd-audio-input.sh]="$(x86 "Framework 13 AMD audio input")"
    [user/hardware/dell/xps13-text-scaling.sh]="$(x86 "Dell XPS 13 text size")"
    [user/hardware/fix-nouveau-cursor.sh]="$(x86 "nouveau hardware cursor on NVIDIA GPUs")"
)

: > "$OUT"
: > "$LOG"
chmod 0644 "$LOG"

install -d -m 0700 -o "$U" -g "$U" "$RUNDIR"

# --- 1. the adapted install/ copy ---------------------------------------------
rm -rf "$ADAPTED"
cp -a "$OMARCHY_PATH/install" "$ADAPTED"
re_leaf='^run_logged[[:space:]]+"[$]OMARCHY_INSTALL/([^"]+)"[[:space:]]*$'
{
    echo '# user/all.sh, adapted at build time by omarchy-tab-s2'
    echo '# (rootfs/omarchy-user-setup.sh): the same leaves, from'
    echo "# $OMARCHY_PATH/install, each through run_logged; a failure is recorded"
    echo '# instead of stopping omarchy-provision-user.'
    echo 't715_leaf() {'
    echo '  if run_logged "$1"; then'
    echo '    printf "T715-LEAF\t%s\tok\n" "$2"'
    echo '  else'
    echo '    printf "T715-LEAF\t%s\tfailed (exit %s)\n" "$2" "$?"'
    echo '  fi'
    echo '}'
    echo 't715_skip() { printf "T715-LEAF\t%s\tskipped\t%s\n" "$1" "$2"; }'
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        if [[ ! $line =~ $re_leaf ]]; then
            record "user/all.sh" "not run" "line not understood by this runner: $line"
            continue
        fi
        rel="${BASH_REMATCH[1]}"
        if [ -n "${SKIP[$rel]+x}" ]; then
            printf 't715_skip %q %q\n' "$rel" "${SKIP[$rel]}"
        else
            printf 't715_leaf "%s/install/%s" "%s"\n' "$OMARCHY_PATH" "$rel" "$rel"
        fi
    done < "$OMARCHY_PATH/install/user/all.sh"
    echo 'echo "T715-ALL-DONE"'
} > "$ADAPTED/user/all.sh"
chmod -R a+rX "$ADAPTED"

# --- 1. omarchy-provision-user ------------------------------------------------
runner=()
command -v dbus-run-session >/dev/null 2>&1 && runner=(dbus-run-session --)
echo "=== omarchy-provision-user --force --first-install (as $U) ===" >> "$LOG"
as_user "${runner[@]}" omarchy-provision-user --force --first-install >> "$LOG" 2>&1
prc=$?
echo "=== exit $prc ===" >> "$LOG"

while IFS=$'\t' read -r _ rel status reason; do
    case "$status" in failed*) reason="${reason:-see /var/log/omarchy-install.log}" ;; esac
    record "$rel" "$status" "$reason"
done < <(grep -a $'^T715-LEAF\t' "$LOG")
grep -aqx 'T715-ALL-DONE' "$LOG" \
    || record "user/all.sh" "not reached" "omarchy-provision-user stopped before its leaves: see $LOG"

marker="$H/.local/state/omarchy/done/finalize-user"
if [ "$prc" -eq 0 ]; then
    record "omarchy-provision-user" ok "--force --first-install"
else
    record "omarchy-provision-user" "failed (exit $prc)" "--force --first-install; see $LOG"
fi

# --- 2. its remaining steps, if it stopped after the leaves -----------------
if [ "$prc" -ne 0 ] && [ ! -f "$marker" ]; then
    if grep -aqx 'T715-ALL-DONE' "$LOG"; then
        # After its leaves, omarchy-provision-user runs
        # omarchy-refresh-applications, then makes chromium.desktop the
        # default browser. Same exit status from that step alone: it is the
        # one that stopped the script.
        as_user env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser chromium.desktop >> "$LOG" 2>&1
        xrc=$?
        if [ "$xrc" -eq "$prc" ]; then
            record "provision-user: failing step" identified "xdg-settings set default-web-browser chromium.desktop exits $xrc (no chromium.desktop on armv7h); the steps after it run below"
        else
            record "provision-user: failing step" unknown "exit $prc, not the browser step (exit $xrc); every step after the leaves runs below"
            step "provision-user: omarchy-refresh-applications" "run by the builder" \
                as_user omarchy-refresh-applications
        fi
        step "provision-user: mailto handler" "run by the builder: xdg-mime default HEY.desktop x-scheme-handler/mailto" \
            as_user xdg-mime default HEY.desktop x-scheme-handler/mailto
        step "provision-user: migration markers" "run by the builder: every shipped migration marked done (first install)" \
            as_user bash -c 'mkdir -p ~/.local/state/omarchy/migrations && for m in "$OMARCHY_PATH"/migrations/*.sh; do [ -f "$m" ] && touch ~/.local/state/omarchy/migrations/"${m##*/}"; done'
        step "provision-user: finalize-user marker" "run by the builder: omarchy-done mark finalize-user" \
            as_user omarchy-done mark finalize-user
    else
        record "provision-user: remaining steps" "not run" "omarchy-provision-user stopped before its leaves"
    fi
fi

# --- 3. Firefox as the browser --------------------------------------------------
if pacman -Q firefox >/dev/null 2>&1; then
    step "firefox: policy directory" "browser_policy_setup_firefox_distribution (omarchy-install-browser firefox)" \
        env OMARCHY_PATH="$OMARCHY_PATH" bash -c 'source "$OMARCHY_PATH/install/helpers/browser-policy.sh" && browser_policy_setup_firefox_distribution /usr/lib/firefox/distribution'
    step "firefox: Wayland" "~/.config/environment.d/omarchy-firefox-wayland.conf (omarchy-install-browser firefox)" \
        as_user bash -c 'mkdir -p ~/.config/environment.d && echo "MOZ_ENABLE_WAYLAND=1" > ~/.config/environment.d/omarchy-firefox-wayland.conf'
else
    record "firefox" "not installed" "see the extras table"
fi
step "chromium: default browser" "xdg-settings, as omarchy-default-browser chromium does" \
    as_user env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser chromium.desktop

# --- 4. tablet settings ---------------------------------------------------------
as_user mkdir -p "$H/Work/tries"

mon="$H/.config/hypr/monitors.lua"
if [ -f "$mon" ] && grep -q '^local omarchy_monitor_scale = ' "$mon"; then
    sed -i 's/^local omarchy_monitor_scale = .*/-- SM-T715: 1536x2048 panel at scale 2 (768x1024 logical), set by omarchy-tab-s2.\nlocal omarchy_monitor_scale = 2/' "$mon"
fi
if grep -qx 'local omarchy_monitor_scale = 2' "$mon" 2>/dev/null; then
    record "monitors.lua: scale 2" ok "local omarchy_monitor_scale = 2"
else
    record "monitors.lua: scale 2" failed "no omarchy_monitor_scale line in $mon"
fi

as_user mkdir -p "$H/.config/uwsm"
envf="$H/.config/uwsm/env"
[ -f "$envf" ] && sed -i '/AQ_DRM_DEVICES/d' "$envf"
{
    echo '# SM-T715: Hyprland (aquamarine) must drive card0, exynos-drm (the panel);'
    echo '# card1 is panfrost (render only). Set by omarchy-tab-s2.'
    echo 'export AQ_DRM_DEVICES=/dev/dri/card0'
} >> "$envf"
record "uwsm env: AQ_DRM_DEVICES" ok "$envf"

lnf="$H/.config/hypr/looknfeel.lua"
if [ -f "$lnf" ] && ! grep -q '^-- SM-T715 begin' "$lnf"; then
    { echo; cat /t715/t715-looknfeel.lua; } >> "$lnf"
fi
if grep -q '^-- SM-T715 end' "$lnf" 2>/dev/null; then
    record "looknfeel.lua: tablet block" ok "opaque windows, shorter animations, no Xwayland, the pointer for a mouse (rootfs/t715-looknfeel.lua)"
else
    record "looknfeel.lua: tablet block" failed "no $lnf from Omarchy's skel"
fi

step "toggle: suspend-off" "omarchy-toggle suspend-off on: no Suspend entry in the system menu" \
    as_user omarchy-toggle suspend-off on

# --- 4b. touch layer P1 (docs/image/ROOTFS.md) -------------------------------------------
# The tablet block: hardware keys and the cover (t715-keys handles them), the
# on-screen keyboard's layers, window sizes. At the end of hyprland.lua, after Omarchy's defaults and the
# toggles; smoke-check.sh verifies the whole configuration.
hl="$H/.config/hypr/hyprland.lua"
if [ -f "$hl" ] && ! grep -q '^-- SM-T715 tablet begin' "$hl"; then
    { echo; cat /t715/t715-tablet.lua; } >> "$hl"
fi
if grep -q '^-- SM-T715 tablet end' "$hl" 2>/dev/null; then
    record "hyprland.lua: tablet block" ok "Power and Home to t715-keys, keys never wake the screen, no lid binds, the keyboard's layer rules, floating sizes (rootfs/t715-tablet.lua)"
else
    record "hyprland.lua: tablet block" failed "no $hl from Omarchy's skel"
fi

# squeekboard shows itself only while this is on. dconf keeps it in
# ~/.config/dconf/user, written by dconf-service on the private session bus.
osk=(org.gnome.desktop.a11y.applications screen-keyboard-enabled)
as_user "${runner[@]}" gsettings set "${osk[@]}" true >> "$LOG" 2>&1
if [ "$(as_user "${runner[@]}" gsettings get "${osk[@]}" 2>>"$LOG")" = true ] \
        && [ -s "$H/.config/dconf/user" ]; then
    record "gsettings: screen-keyboard-enabled" ok "${osk[*]} true, in ~/.config/dconf/user"
else
    record "gsettings: screen-keyboard-enabled" failed "${osk[*]} not true in dconf; see $LOG"
fi

# squeekboard's layout is the first input source (GNOME's setting, which it
# follows): T715_XKB's, US QWERTY or French AZERTY, then the other one tap
# away in its layout menu.
src=(org.gnome.desktop.input-sources sources)
if [ "$T715_XKB" = fr ]; then
    want="[('xkb', 'fr'), ('xkb', 'us')]"
else
    want="[('xkb', 'us'), ('xkb', 'fr')]"
fi
as_user "${runner[@]}" gsettings set "${src[@]}" "$want" >> "$LOG" 2>&1
if [ "$(as_user "${runner[@]}" gsettings get "${src[@]}" 2>>"$LOG")" = "$want" ]; then
    record "gsettings: input-sources" ok "${src[*]} $want (squeekboard: $T715_XKB first)"
else
    record "gsettings: input-sources" failed "${src[*]} is not $want; see $LOG"
fi

# squeekboard's terminal layouts with an Esc key, US and French
# (GPL-3.0-or-later, NOTICE next to them), from the only place squeekboard
# reads layouts besides its own: a terminal gets terminal/<first input source>.
layouts=/usr/share/t715-omarchy/squeekboard/keyboards/terminal
step "squeekboard: terminal layouts" "~/.local/share/squeekboard/keyboards/terminal/{us,fr}.yaml -> $layouts" \
    as_user bash -c 'mkdir -p ~/.local/share/squeekboard/keyboards/terminal &&
        for l in us fr; do
            ln -sfn "$1/$l.yaml" ~/.local/share/squeekboard/keyboards/terminal/$l.yaml && [ -f "$1/$l.yaml" ] || exit 1
        done' _ "$layouts"

# Auto-rotation on, for alarm only (docs/image/ROTATION.md, owner's check of
# 2026-11-03): a user link, not --global, so that the Rotation tile can still
# turn it off.
step "rotation: on" "~/.config/systemd/user/graphical-session.target.wants/omamobile-autorotate.service" \
    as_user bash -c 'mkdir -p ~/.config/systemd/user/graphical-session.target.wants &&
        ln -sfn /etc/systemd/user/omamobile-autorotate.service \
            ~/.config/systemd/user/graphical-session.target.wants/omamobile-autorotate.service &&
        [ -f /etc/systemd/user/omamobile-autorotate.service ]'

# Lock in the system menu only once a PIN is set: before that nothing could
# leave the lock. Omarchy's menu extension file, as omarchy-mobile hides rows
# (a reused id with a failing "when"). A PIN row sets it (omamobile-set-pin).
# Two rows that cannot work here go the same way: Update > Firmware would install
# fwupd for a device with no LVFS firmware, and Update > Config > Plymouth rebuilds
# an initramfs for a kernel no package owns.
ext="$H/.config/omarchy/extensions/omarchy-menu.jsonc"
if [ -f "$ext" ] && ! grep -q '"system.lock"' "$ext"; then
    awk '!done && /^[[:space:]]*\{/ {
            print
            print "  // SM-T715 (omarchy-tab-s2): no Lock until a PIN is set; nothing could"
            print "  // leave the lock."
            print "  \"system.lock\": {\"when\": \"omarchy-toggle-enabled lock-on-start\"},"
            print "  \"system.pin\": {\"icon\":\"󰌾\",\"label\":\"PIN\",\"description\":\"Set or change the PIN that unlocks this tablet\",\"action\":\"omamobile-set-pin\"},"
            print "  // SM-T715: no fwupd firmware, and the kernel lives in BOOT."
            print "  \"update.firmware\": {\"when\": \"false\"},"
            print "  \"update.config.plymouth\": {\"when\": \"false\"},"
            done = 1; next
         } { print }' "$ext" > "$ext.t715" && mv -f "$ext.t715" "$ext"
fi
if grep -q '^  "system.lock": {"when": "omarchy-toggle-enabled lock-on-start"},$' "$ext" 2>/dev/null &&
   grep -q '^  "system.pin": {' "$ext" &&
   grep -q '^  "update.firmware": {"when": "false"},$' "$ext" &&
   grep -q '^  "update.config.plymouth": {"when": "false"},$' "$ext"; then
    record "menu: dead rows" ok "system.lock until a PIN is set, a PIN row, update.firmware and update.config.plymouth hidden in ~/.config/omarchy/extensions/omarchy-menu.jsonc"
else
    record "menu: dead rows" failed "no menu extension file from Omarchy's skel ($ext)"
fi

# --- 5. touch layer P2 (docs/image/ROOTFS.md "Touch layer P2") -----------------------------
# omamobile-setup-user is omarchy-mobile's per-user setup: each step runs once,
# tracked by an omarchy-done marker. The steps below are phone-only, or done
# by the image already (touch layer P1, the build's toggles): their markers
# are set first, so the script skips them. Run after P1's steps, so that its
# terminal-layout step finds P1's link and leaves it.
share=/usr/share/omamobile/shell
done_dir="$H/.local/state/omarchy/done"
premark=(
    "omamobile-monitor-scale|scale 3 is the phone's 480x1040; the tablet keeps scale 2 (768x1024 logical, monitors.lua)"
    "omamobile-gdk-scale|follows the scale-3 step; Omarchy's GDK_SCALE=2 matches scale 2"
    "omamobile-osk|P1 has the on-screen keyboard: squeekboard started by t715-squeekboard.service, its gsettings set at build time"
    "omamobile-phone-rules|hypr/phone.lua (every window maximized, no gaps, omamobile-keys bindings) is not shipped; rootfs/t715-tablet.lua has the tablet's rules"
    "omamobile-hide-cursor|a tablet takes a mouse: the tablet block of looknfeel.lua (rootfs/t715-looknfeel.lua) shows the pointer while it moves and hides it on touch or after 3 s still"
    "omamobile-suspend-off|the build set Omarchy's suspend-off toggle already (omarchy-toggle suspend-off on)"
    "omamobile-idle|a phone's 60 s idle lock: t715-keys locks when the screen goes off, once a PIN is set; Omarchy's idle cycle is off through the tablet profile's zero timers"
    "omamobile-lock-keypad|omamobile-set-pin sets it with the PIN"
    "omamobile-lock-after-screensaver|Omarchy's screensaver never runs: its timer is 0 in the tablet profile's shell.json"
    "omamobile-credential-type|omamobile-set-pin writes it with the PIN"
    "omamobile-menu-pin|the block above adds the PIN row"
    "omamobile-fingerprint-plugin|no fingerprint sensor (omamobile.fingerprint is not shipped)"
    "omamobile-menu-fingerprint|no fingerprint sensor (omamobile.fingerprint is not shipped)"
    "omamobile-call-plugin|no modem (omamobile.call is not shipped)"
    "omamobile-access-plugin|no camera or location to ask about (omamobile.access is not shipped)"
    "omamobile-update-plugin|omamobile-update needs an [omamobile] repository (omamobile.update is not shipped)"
    "omamobile-voice-plugin|no Voxtype daemon or Whisper model on armv7h (omamobile.voice is not shipped, since 0.2.94)"
    "omamobile-menu-voice|the Setup > Voice row would summon omamobile.voice, which is not shipped"
    "omamobile-menu-update|Update > Omarchy stays Omarchy's own (no omamobile-update)"
    "omamobile-chromium-no-first-run|the launcher, pkg/t715-chromium, sets Chromium's flags"
    "omamobile-chromium-mobile|the launcher, pkg/t715-chromium, sets Chromium's flags"
    "omamobile-chromium-scale-2|the launcher, pkg/t715-chromium, sets Chromium's flags"
    "omamobile-chromium-scale-3|the launcher, pkg/t715-chromium, sets Chromium's flags"
    "omamobile-chromium-wayland-ime|the launcher, pkg/t715-chromium, sets Chromium's flags"
)
if [ -x /usr/bin/omamobile-setup-user ]; then
    as_user mkdir -p "$done_dir"
    for entry in "${premark[@]}"; do
        m="${entry%%|*}"
        if as_user omarchy-done mark "$m"; then
            record "omamobile-setup-user: $m" pre-marked "${entry#*|}"
        else
            record "omamobile-setup-user: $m" "failed" "omarchy-done mark $m"
        fi
    done
    before="$(ls "$done_dir" | sort)"
    echo "=== omamobile-setup-user (as $U) ===" >> "$LOG"
    step "omamobile-setup-user" "its remaining steps; markers it set are listed below" \
        as_user omamobile-setup-user
    ran="$(comm -13 <(printf '%s\n' "$before") <(ls "$done_dir" | sort) | tr '\n' ' ')"
    record "omamobile-setup-user: steps run" "$(echo $ran | wc -w | tr -d ' ')" "${ran:-none}"

    # Its profile step seeds shell.json from the package (the tablet profile).
    if cmp -s "$share/profile/shell.json" "$H/.config/omarchy/shell.json"; then
        record "omamobile: shell.json" ok "the tablet profile ($share/profile/shell.json)"
    else
        record "omamobile: shell.json" failed "~/.config/omarchy/shell.json is not $share/profile/shell.json"
    fi
    # The home screens: the tablet's 6x8 grid with the image's apps. Home.qml
    # writes a phone default (4x6, Chromium) only when there is no file.
    if [ ! -e "$H/.config/omamobile/home.json" ]; then
        as_user install -D -m 0644 "$share/profile/home.json" "$H/.config/omamobile/home.json"
    fi
    if cmp -s "$share/profile/home.json" "$H/.config/omamobile/home.json"; then
        record "omamobile: home.json" ok "6x8 grid, clock, toggles, Phone, Messages, Chromium, Firefox, Files, foot, btop, Papers, mpv ($share/profile/home.json)"
    else
        record "omamobile: home.json" failed "~/.config/omamobile/home.json is not $share/profile/home.json"
    fi
    links=""
    for p in "$share"/plugins/omamobile.*; do
        [ "$(readlink "$H/.config/omarchy/plugins/${p##*/}")" = "$p" ] || links="$links ${p##*/}"
    done
    if [ -z "$links" ]; then
        record "omamobile: plugin links" ok "$(cd "$share/plugins" && ls -d omamobile.* | tr '\n' ' ')in ~/.config/omarchy/plugins"
    else
        record "omamobile: plugin links" failed "not linked:$links"
    fi
else
    record "omamobile-setup-user" "not installed" "no /usr/bin/omamobile-setup-user (packages.mobile)"
fi

# Omarchy's web apps (HEY, YouTube, WhatsApp, ...) open in Chromium and stay.
# Its Docker entry needs lazydocker (left out): hidden from the drawer and
# Omarchy's menu with the usual NoDisplay override, in alarm's own copies
# (from Omarchy's skel).
hidden=""
nhidden=0
for f in "$H"/.local/share/applications/*.desktop; do
    [ -f "$f" ] || continue
    grep -qE '^Exec=(.* )?omarchy-launch-docker-tui' "$f" || continue
    grep -q '^NoDisplay=true' "$f" || sed -i '/^\[Desktop Entry\]/a NoDisplay=true' "$f"
    hidden="$hidden${hidden:+, }$(basename "$f" .desktop)"
    nhidden=$((nhidden + 1))
done
record "drawer: entries hidden" "$nhidden" "need Docker: ${hidden:-none}"

# --- cleanup ----------------------------------------------------------------------
chown -R "$U:$U" "$H"
rm -rf "$ADAPTED" "$RUNDIR"
rmdir /run/user 2>/dev/null || true
exit 0
