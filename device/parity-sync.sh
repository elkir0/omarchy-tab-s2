#!/usr/bin/env bash
# Bring a persistent root up to what a new image would have, over SSH: the root
# keeps the owner's data, so it never gets the image itself (docs/DEPLOY.md 11.6).
# Run after `pacman -U` of the packages built from image/pkg/. Safe to run again.
#
# The firewall goes on with a return armed: without a confirmation it turns itself
# off after 5 minutes, should the USB link not survive it.
#
# Usage: device/parity-sync.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSSH="$REPO_ROOT/device/tssh"
O="$REPO_ROOT/image/rootfs/overlay"
copy() { scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }

copy "$O/usr/local/bin/t715-keys" "$O/usr/local/bin/t715-update-check" root@172.16.42.1:/usr/local/bin/
copy "$O/usr/local/sbin/t715-sudo-asks-password" root@172.16.42.1:/usr/local/sbin/
copy "$O/etc/systemd/user/t715-squeekboard.service" "$O/etc/systemd/user/t715-update-check.service" \
     "$O/etc/systemd/user/t715-update-check.timer" root@172.16.42.1:/etc/systemd/user/
copy "$O/etc/NetworkManager/dispatcher.d/50-t715-hotspot-firewall" root@172.16.42.1:/etc/NetworkManager/dispatcher.d/
copy "$O/etc/NetworkManager/conf.d/21-t715-wifi-no-pmf.conf" root@172.16.42.1:/etc/NetworkManager/conf.d/
copy "$O/etc/ufw/user.rules" "$O/etc/ufw/user6.rules" root@172.16.42.1:/etc/ufw/
copy "$REPO_ROOT/image/rootfs/t715-tablet.lua" root@172.16.42.1:/tmp/t715-tablet.lua

"$TSSH" 'bash -s' <<'REMOTE'
set -eu
A=/home/alarm
chmod 755 /usr/local/bin/t715-keys /usr/local/bin/t715-update-check /usr/local/sbin/t715-sudo-asks-password \
    /etc/NetworkManager/dispatcher.d/50-t715-hotspot-firewall
chmod 640 /etc/ufw/user.rules /etc/ufw/user6.rules

python3 - <<'PY'
p = '/home/alarm/.config/hypr/hyprland.lua'
s = open(p).read()
new = open('/tmp/t715-tablet.lua').read().rstrip('\n')
a = s.index('-- SM-T715 tablet begin')
b = s.index('-- SM-T715 tablet end') + len('-- SM-T715 tablet end')
open(p, 'w').write(s[:a] + new + s[b:])

p = '/home/alarm/.config/omarchy/extensions/omarchy-menu.jsonc'
s = open(p).read()
rows = {
    '"system.lock"': '  "system.lock": {"when": "omarchy-toggle-enabled lock-on-start"},\n',
    '"system.pin"': '  "system.pin": {"icon":"󰌾","label":"PIN","description":"Set or change the PIN that unlocks this tablet","action":"omamobile-set-pin"},\n',
    '"update.firmware"': '  "update.firmware": {"when": "false"},\n',
    '"update.config.plymouth"': '  "update.config.plymouth": {"when": "false"},\n',
}
lines = [l + '\n' for l in s.split('\n')]
lines = [l for l in lines if not any(l.lstrip().startswith(k + ':') for k in rows)]
lines.insert(1, ''.join(rows.values()))
open(p, 'w').write(''.join(lines).rstrip('\n') + '\n')
PY
chown alarm:alarm $A/.config/hypr/hyprland.lua $A/.config/omarchy/extensions/omarchy-menu.jsonc

for f in $A/.local/share/applications/*.desktop; do
    grep -qE '^Exec=omarchy-(launch-webapp|webapp-handler-)' "$f" || continue
    sed -i '/^NoDisplay=true$/d' "$f"
done

systemctl --global enable t715-update-check.timer >/dev/null
systemctl --user -M alarm@ daemon-reload
systemctl --user -M alarm@ enable --now t715-update-check.timer >/dev/null
systemctl --user -M alarm@ restart t715-keys

if [ "$(ufw status | head -1)" != "Status: active" ]; then
    systemd-run --quiet --unit=t715-fw-rollback --on-active=300 /usr/bin/ufw --force disable
fi
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw >/dev/null 2>&1
ufw --force enable >/dev/null
REMOTE

# Still here over USB with the firewall on: keep it.
"$TSSH" 'systemctl stop t715-fw-rollback.timer 2>/dev/null || true; ufw status | head -1; systemctl is-enabled ufw'
