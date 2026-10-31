# Builds the LineageOS dtbhtool reference binaries (mkbootimg / mkdtbimg /
# unpackbootimg / unpackdtbhimg) from the read-only sources in
# src/hardware_samsung-18.1/dtbhtool with plain gcc on debian:trixie
# (arm64, native on Apple silicon).
#
# Nothing under src/ is modified: the sources are mounted read-only at
# /src at run time.  The portability shims (the device-specific
# samsung_dtbh.h the C sources expect to be "provided by the device tree",
# plus dtbimg.h discovery) come from boot/docker/dtbhtool-shims/, which is
# the Docker build context.
#
# Build (from the repo root), or just run boot/build-dtbhtool-ref.sh:
#   docker build --platform linux/arm64 \
#                -f boot/docker/dtbhtool-ref.Dockerfile \
#                -t dtbhtool-ref boot/docker
#   docker run --rm --platform linux/arm64 \
#       -v "$PWD/src/hardware_samsung-18.1/dtbhtool:/src:ro" \
#       -v "$PWD/out/tools:/out" dtbhtool-ref
#
# Libraries:
#   libfdt-dev   -> fdt_check_header/fdt_path_offset/fdt_getprop (dtbimg.c)
#   libssl-dev   -> openssl/sha.h SHA1_* (mkbootimg.c:39,286-297); the
#                   SHA1_Init/Update/Final API is deprecated in OpenSSL 3 but
#                   still present, which is all the reference build needs.

FROM --platform=linux/arm64 debian:trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc libc6-dev libfdt-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Shims: samsung_dtbh.h (device constants) sits in /shims; the libdtbimg
# header stays with the mounted sources.
COPY dtbhtool-shims /shims

# The C sources are mounted read-only at /src; binaries land in /out.
CMD ["bash", "-c", "set -eux; cd /src; \
    gcc -O2 -Wall -o /out/mkdtbimg \
        mkdtbimg.c dtbimg.c \
        -I/src/libdtbimg -I/shims -lfdt; \
    gcc -O2 -Wall -o /out/mkbootimg \
        mkbootimg.c dtbimg.c \
        -I/src/libdtbimg -I/shims -lfdt -lcrypto; \
    gcc -O2 -Wall -o /out/unpackbootimg unpackbootimg.c; \
    gcc -O2 -Wall -o /out/unpackdtbhimg unpackdtbhimg.c; \
    ls -l /out"]
