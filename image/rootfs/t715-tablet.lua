-- SM-T715 tablet begin (omarchy-tab-s2, rootfs/t715-tablet.lua)
-- Touch layers P1 and P2 (docs/journal/PLAN.md §3, docs/image/ROOTFS.md "Touch layer P1"
-- and "Touch layer P2"): the on-screen keyboard, the hardware keys, window
-- sizes for an 8" portrait panel (768x1024 logical) and the touch shell's
-- layer rules. Adapted from omarchy-mobile's hypr/phone.lua
-- (5f7ba48, MIT, Copyright (c) 2026 Derek Ross); its phone-only parts are
-- left out. Appended to ~/.config/hypr/hyprland.lua, so it loads after
-- Omarchy's defaults, the user's files and the toggles.
-- Keep it free of errors: Hyprland's error bar renders text, which can
-- deadlock Hyprland on this device (docs/journal/ONDEVICE-2026-10-28.md); the image
-- build runs Hyprland --verify-config on it.

-- Hardware keys. t715-keys (a user service that reads the gpio-keys device)
-- handles Power and Home: screen off and on, Omarchy's system menu when
-- Power is held, the touch shell's home screen and, when Home is held, its
-- recent apps (omamobile.home, omamobile.switcher); and the cover (below).
-- Omarchy binds Power to its system menu, and Hyprland passes unbound keys
-- to the focused app (Firefox goes to its home page on XF86HomePage), so
-- both keys are bound to nothing here.
hl.unbind("XF86PowerOff")
o.bind("XF86PowerOff", "Power key (t715-keys)", function() end, { locked = true })
o.bind("XF86HomePage", "Home key (t715-keys)", function() end, { locked = true })
-- The touch keys too (tc300k.ko, read by t715-keys): Back and Recent, which
-- reports KEY_SCALE, so a press never reaches an app behind a dark screen.
o.bind("XF86Back", "Back key (t715-keys)", function() end, { locked = true })
o.bind("XF86LaunchA", "Recent key (t715-keys)", function() end, { locked = true })

-- Only t715-keys wakes the screen, from the screen's state: with Omarchy's
-- key_press_enables_dpms the press itself would light the panel and the
-- release turn it off again (phone.lua's reason). A mouse does not wake it
-- either, so the touchscreen, which t715-keys turns off with the panel
-- (Hyprland delivers touches to apps while the panel is off, and touch never
-- wakes it), always comes back with it.
hl.config({ misc = { key_press_enables_dpms = false, mouse_move_enables_dpms = false } })

-- The cover (its Hall sensor, a lid switch once the device tree has it):
-- Omarchy's laptop lid binds lock the session when the lid closes and turn
-- the internal panel off while an external monitor is driven (clamshell).
-- The tablet has no other display: both removed. t715-keys turns the screen
-- off and on with the cover, and locks if a PIN is set; logind ignores it
-- (/etc/systemd/logind.conf.d/90-t715-lid.conf).
hl.unbind("switch:on:Lid Switch")
hl.unbind("switch:off:Lid Switch")

-- On-screen keyboard: squeekboard shows itself when a text field takes
-- focus (text-input-v3, which Hyprland relays to its input-method-v2; the
-- environment is in /etc/environment.d/20-t715-osk.conf). The
-- t715-squeekboard.service user unit starts it with the session, not
-- Hyprland. Omarchy's fcitx5 is kept off, as it would take the input-method
-- slot.
-- Its layer ("osk") pops up without Hyprland's layer animation, like
-- Omarchy's own shell surfaces, and stays usable above a session lock
-- (phone.lua: a lock otherwise hides every other surface, keyboards included).
hl.layer_rule({ match = { namespace = "^osk$" }, no_anim = true, animation = "none" })
hl.layer_rule({ match = { namespace = "^osk$" }, above_lock = 2 })
-- ...and the touch shell's hide button over it (omamobile.keyboard), with it.
hl.layer_rule({ match = { namespace = "^omamobile-osk-hide$" }, above_lock = 2, no_anim = true })

-- Calls (omamobile.call) above the lock too, taking touches (2): a ringing
-- call is answered from the lock screen, and the card offers call actions only.
hl.layer_rule({ match = { namespace = "^omamobile-call(-top)?$" }, above_lock = 2 })

-- Omarchy's lock comes up at login once a PIN is set (the lock-on-start toggle
-- of omamobile-set-pin): without one a lock could not be left.
o.launch_on_start("bash -c 'omarchy-toggle-enabled lock-on-start || exit 0; "
    .. "for _ in $(seq 100); do omarchy-shell lock status >/dev/null 2>&1 && break; sleep 0.2; done; "
    .. "omarchy-system-lock'")

-- The touch shell (omamobile-shell, touch layer P2) needs nothing else from
-- Hyprland: its gestures are layer-shell strips (the bar's pull-down, the
-- home pill, the side edges for back). Hyprland's own touch workspace swipe
-- (gestures:workspace_swipe_touch) stays off, or it would fight them.

-- Floating windows. Omarchy floats its terminals, btop and dialogs at
-- 875x600 and About at 920x480, wider than the 768 px portrait screen: fit
-- them to it instead (phone.lua maximizes every window, which a tablet does
-- not need: it tiles two windows at a usable size). A later rule wins.
o.window({ tag = "floating-window" }, { size = { "(monitor_w*0.94)", "(monitor_h*0.6)" } })
o.window("org.omarchy.about", { size = { "(monitor_w*0.94)", "(monitor_h*0.47)" } })
-- SM-T715 tablet end
