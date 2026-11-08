-- SM-T715 begin (omarchy-tab-s2, rootfs/t715-looknfeel.lua)
-- Mali-T760 driving a 1536x2048 panel: draw less, animate shorter.
-- hyprland.lua loads this file after Omarchy's defaults and the theme's
-- overrides, so these values win; Omarchy updates only touch /usr/share/omarchy.
-- Keep it free of errors: Hyprland's error bar renders text, which can
-- deadlock Hyprland on this device (docs/journal/ONDEVICE-2026-10-28.md).

-- Opaque windows. Omarchy gives every window 0.985/0.96 opacity
-- (default/hypr/windows.lua); with any alpha below 1 Hyprland cannot occlude
-- what lies behind, so the full-screen wallpaper and lower windows are
-- redrawn and blended on every frame. A later rule wins.
o.window(".*", { opacity = "1 1" })

hl.config({
  -- Omarchy's defaults already have these off; some themes turn them on.
  decoration = {
    rounding = 0,
    shadow = { enabled = false },
    blur = { enabled = false },
  },
  -- No X11 application in this image, and Xwayland starts eagerly.
  xwayland = { enabled = false },
})

-- Animations follow the Battery saver: on in balanced (the short ones
-- below), off while t715-power-profile's flag /run/t715-power/saver
-- exists. This read covers Hyprland's start and every config reload;
-- t715-animations (a user path unit on the flag) flips them in the
-- running session. With the GPU at a fixed 266 MHz (kernels before #7)
-- the user found the desktop snappier without them; #8 scales the GPU
-- up to 700 MHz.
local t715_saver = io.open("/run/t715-power/saver", "r")
if t715_saver then t715_saver:close() end
hl.config({ animations = { enabled = t715_saver == nil } })

-- The animations in use: short ones (speed unit: 100 ms; Omarchy uses
-- 150 to 540 ms), none when something closes. Omarchy's curves
-- (default/hypr/looknfeel.lua).
hl.animation({ leaf = "border", enabled = false })
hl.animation({ leaf = "windows", enabled = true, speed = 2, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = false })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = false })
hl.animation({ leaf = "fade", enabled = true, speed = 1.5, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 2, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 2, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = false })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = false })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 1.5, bezier = "easeOutQuint", style = "slidevert" })
-- SM-T715 end
