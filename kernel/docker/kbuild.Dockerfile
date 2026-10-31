# Reproducible cross-compilation environment for the 32-bit (ARMv7/LPAE)
# mainline Linux kernel for the Samsung Galaxy Tab S2 8.0 LTE (SM-T715,
# Exynos5433).  debian:trixie runs natively on Apple-silicon Docker, and
# the arm-linux-gnueabihf cross toolchain builds the ARMv7 kernel.
#
# The kernel tree in src/linux-6.12 is never written to by the
# image build itself: it is bind-mounted at /kbuild/src at run time and
# the out-of-tree build directory lives in the named volume
# t715-kbuild-out mounted at /kbuild/out (see kernel/kbuild-mainline.sh).
#
# Build (from the repo root):
#   docker build --platform linux/arm64 \
#                -f kernel/docker/kbuild.Dockerfile \
#                -t t715-kbuild kernel/docker
#
# Packages:
#   gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf   -> cross kernel
#   gcc binutils make bc bison flex libssl-dev libelf-dev  -> host tools (kallsyms
#       is built with the native compiler; kernel build host-programs)
#   cpio kmod xz-utils lz4                                  -> initramfs, modules
#   python3 device-tree-compiler                            -> dt_binding_check,
#       dtc (for the arm64 non-regression check inside the container)
#   git rsync                                               -> scripts/setlocalversion
#       (git), artifact copy out of the volume (rsync)

FROM --platform=linux/arm64 debian:trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc-arm-linux-gnueabihf \
        binutils-arm-linux-gnueabihf \
        gcc \
        make \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        cpio \
        kmod \
        xz-utils \
        lz4 \
        python3 \
        device-tree-compiler \
        git \
        rsync \
    && rm -rf /var/lib/apt/lists/*
