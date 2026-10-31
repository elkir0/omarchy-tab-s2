/* LD_PRELOAD for Hyprland on the SM-T715, loaded by the /usr/local/bin/Hyprland
 * wrapper (rootfs/overlay; docs/journal/ONDEVICE-2026-10-28.md).
 * Hyprland's linux-dmabuf commence() imports every client buffer into the
 * render node of the display device (exynos-drm), which rejects the
 * non-contiguous buffers panfrost allocates ("buffer chunks must be mapped
 * contiguously"), so every GPU client is killed on its first attach.
 * Fake success for that check only: the call must come from the Hyprland
 * executable itself (not Mesa, not aquamarine) and target an exynos-drm node.
 *
 * Also, for every caller in Hyprland: Mesa's kmsro imports each client
 * buffer into the display device's node (renderonly) and releases it with
 * DRM_IOCTL_MODE_DESTROY_DUMB, which the kernel refuses on a render node
 * (no DRM_RENDER_ALLOW). On renderD128 every successful import then stayed
 * held: about 13 MB per drawer opening here, and with the DECON SysMMU, where
 * every import succeeds, exynos-drm's 1 GiB IOMMU window filled within
 * twenty minutes (docs/journal/ONDEVICE-2026-10-29.md). When DESTROY_DUMB fails with
 * EACCES on a render node, the handle is closed with DRM_IOCTL_GEM_CLOSE,
 * which is allowed there and does the same (drm_gem_handle_delete).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define FAKE_HANDLE 0x7ffffff0u

static int on_exynos(int fd)
{
    struct stat st;
    char path[96], link[128];
    ssize_t n;

    if (fstat(fd, &st) || !S_ISCHR(st.st_mode) || major(st.st_rdev) != 226)
        return 0;
    snprintf(path, sizeof path, "/sys/dev/char/%u:%u/device/driver",
             major(st.st_rdev), minor(st.st_rdev));
    n = readlink(path, link, sizeof link - 1);
    if (n <= 0)
        return 0;
    link[n] = 0;
    return strstr(link, "exynos-drm") != NULL;
}

static int from_main_program(void *ret)
{
    Dl_info info;
    return dladdr(ret, &info) && info.dli_fname && !strstr(info.dli_fname, ".so");
}

int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
    static int (*real)(int, int, uint32_t *);
    int ret;

    if (!real)
        real = (int (*)(int, int, uint32_t *))dlsym(RTLD_NEXT, "drmPrimeFDToHandle");
    ret = real(fd, prime_fd, handle);
    if (ret && from_main_program(__builtin_return_address(0)) && on_exynos(fd)) {
        *handle = FAKE_HANDLE;
        return 0;
    }
    return ret;
}

int drmCloseBufferHandle(int fd, uint32_t handle)
{
    static int (*real)(int, uint32_t);

    if (handle == FAKE_HANDLE)
        return 0;
    if (!real)
        real = (int (*)(int, uint32_t))dlsym(RTLD_NEXT, "drmCloseBufferHandle");
    return real(fd, handle);
}

static int render_node(int fd)
{
    struct stat st;

    return !fstat(fd, &st) && S_ISCHR(st.st_mode) && major(st.st_rdev) == 226 &&
           minor(st.st_rdev) >= 128;
}

int drmIoctl(int fd, unsigned long request, void *arg)
{
    static int (*real)(int, unsigned long, void *);
    static int told;
    int ret;

    if (!real)
        real = (int (*)(int, unsigned long, void *))dlsym(RTLD_NEXT, "drmIoctl");
    ret = real(fd, request, arg);
    if (ret && errno == EACCES && request == DRM_IOCTL_MODE_DESTROY_DUMB && render_node(fd)) {
        struct drm_gem_close close_args = {
            .handle = ((struct drm_mode_destroy_dumb *)arg)->handle,
        };

        ret = real(fd, DRM_IOCTL_GEM_CLOSE, &close_args);
        if (!told) {
            told = 1;
            fprintf(stderr, "t715-dmabuf-check-shim: DESTROY_DUMB refused on a render node, "
                    "closed with GEM_CLOSE instead (%s)\n", ret ? "failed" : "ok");
        }
    }
    return ret;
}

/* Hyprland only: its clients must not inherit the preload. */
__attribute__((constructor)) static void drop_preload(void)
{
    unsetenv("LD_PRELOAD");
}
