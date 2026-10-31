// SM-T715 (omarchy-tab-s2). Firefox prefers GLES over desktop GL only on
// aarch64 (StaticPrefList.yaml, gfx.egl.prefer-gles.enabled). On armv7h it
// first asks EGL for a desktop GL 3.2 core context, which panfrost on the
// Mali-T760 cannot give (GL 3.1 / GLES 3.1): EGL_BAD_MATCH (0x3009), then
// software WebRender. Omarchy only rewrites distribution/policies.json.
// Kept for WebGL, which still uses EGL.
pref("gfx.egl.prefer-gles.enabled", true);

// WebRender on the CPU (SWGL) rather than the GPU. The Mali-T760 runs at its
// 266 MHz boot clock (no devfreq), and Firefox's GPU WebRender saturated it:
// a YouTube music video drew 7-9 frames/s with the GPU at 110 % and 7 of the
// 8 cores idle. With SWGL the same video drew 58-62 frames/s, GPU 32 %,
// 2.6 cores busy (docs/journal/ONDEVICE-2026-10-29.md, "Firefox on the CPU").
pref("gfx.webrender.software", true);

// No AV1: YouTube then serves VP9, which this CPU decodes about 2.7 times
// faster (1080p synthetic clips, all cores: VP9 128 frames/s on 5.6 cores,
// AV1 48 on 3), and the CPU also renders the pages now.
pref("media.av1.enabled", false);

// A fresh profile at every boot (RAM overlay): skip the welcome and
// default-browser pages that would greet each one.
pref("browser.aboutwelcome.enabled", false);
pref("browser.shell.checkDefaultBrowser", false);
pref("browser.startup.homepage_override.mstone", "ignore");
pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
