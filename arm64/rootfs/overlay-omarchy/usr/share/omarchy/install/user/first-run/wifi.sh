# SM-T715 (omarchy-tab-s2, rootfs/overlay; docs/image/ROOTFS.md "First run"):
# replaces Omarchy's first-run Wi-Fi and update notices. The rescue's root is a
# RAM overlay, so there first run happens at every boot.
# - Wi-Fi: Omarchy's notice is critical (it never expires) and opens
#   omarchy.network, which the tablet shell doesn't load; this one expires
#   and opens quick settings, where the Wi-Fi tile is.
# - No "Update System" notice here: t715-update-check.timer says so when an
#   update really exists, once per version.

notify_wifi() {
  omarchy-notification-send -u normal -g 󰖩 "Setup Wi-Fi" "Click to open quick settings and pick a network." \
    --exec omarchy-shell shell toggle omamobile.quicksettings {}
}

announce_network() {
  # As Omarchy's: wait for NetworkManager's startup to settle, then ask once.
  nm-online -q -s -t 30
  nm-online -q -x -t 30 || notify_wifi
}

# Detached, so a slow or absent connection never holds up the rest of first run.
announce_network &
