# SPDX-License-Identifier: GPL-2.0-or-later
# shannon-loader: build, tests, ARMv7 cross build.
#
#   make                  host binary (build/<arch>/shannon-loader)
#   make test             all offline tests (Linux only; see README)
#   make cross            static ARMv7 hard-float binary build/shannon-loader-armv7
#   make docker-test      run `make test` in the t715-kbuild image (from macOS)
#   make docker-cross     run `make cross` in the t715-omarchy:dev-armv7h image

CC            ?= cc
OBJDUMP       ?= objdump
CROSS_CC      ?= arm-linux-gnueabihf-gcc
CROSS_OBJDUMP ?= arm-linux-gnueabihf-objdump
FIXDIR        ?= /tmp/shannon-loader-fixtures

ARCH := $(shell uname -m)
B    := build/$(ARCH)
X    := build/armv7

STD   := -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64
WARN  := -Wall -Wextra -Werror -Wshadow -Wformat=2 -Wstrict-prototypes \
         -Wmissing-prototypes -Wvla -Wpointer-arith -Wundef
OPT   ?= -O2 -g
CF    := $(STD) $(WARN) $(OPT) -Isrc

CORE_SRC := src/sl_loader.c src/sl_toc.c src/sl_nv.c src/sl_log.c \
            src/sl_crc32.c src/sl_sha256.c src/sl_md5.c src/sl_ops_linux.c \
            src/sl_state.c
HASH_SRC := src/sl_crc32.c src/sl_sha256.c src/sl_md5.c
TEST_SRC := tests/test_main.c tests/mock.c tests/fixtures.c
HDRS     := $(wildcard src/*.h) $(wildcard tests/*.h)

CORE_OBJ := $(patsubst src/%.c,$(B)/obj/%.o,$(CORE_SRC))
XOBJ     := $(patsubst src/%.c,$(X)/obj/%.o,$(CORE_SRC) src/sl_main.c)

.PHONY: all test cross clean docker-test docker-cross

all: $(B)/shannon-loader

$(B)/obj/%.o: src/%.c $(HDRS)
	@mkdir -p $(@D)
	$(CC) $(CF) -c $< -o $@

$(B)/shannon-loader: $(CORE_OBJ) $(B)/obj/sl_main.o
	$(CC) $(CF) $^ -o $@

# --- tests --------------------------------------------------------------

$(B)/mkfixtures: tests/mkfixtures.c tests/fixtures.c $(HASH_SRC) $(HDRS)
	@mkdir -p $(@D)
	$(CC) $(CF) -Itests tests/mkfixtures.c tests/fixtures.c $(HASH_SRC) -o $@

$(B)/test_loader: $(TEST_SRC) $(CORE_SRC) $(HDRS)
	$(CC) $(CF) -Itests -fsanitize=undefined -fno-sanitize-recover=all \
		$(TEST_SRC) $(CORE_SRC) -o $@

$(B)/test_loader_asan: $(TEST_SRC) $(CORE_SRC) $(HDRS)
	$(CC) $(CF) -Itests -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
		-fno-sanitize-recover=all $(TEST_SRC) $(CORE_SRC) -o $@

$(B)/test_hashes: tests/test_hashes.c $(HASH_SRC) $(HDRS)
	$(CC) $(CF) tests/test_hashes.c $(HASH_SRC) -o $@

# the interposer keeps the plain symbol names: no _FILE_OFFSET_BITS, no fortify
$(B)/nv_guard.so: tests/nv_guard.c
	@mkdir -p $(@D)
	$(CC) -std=gnu11 -Wall -Wextra -Werror -Wno-format-truncation -O1 -U_FORTIFY_SOURCE -fPIC -shared \
		$< -o $@ -ldl

$(B)/guard_selftest: tests/guard_selftest.c
	$(CC) -std=gnu11 -Wall -Wextra -O1 -U_FORTIFY_SOURCE $< -o $@

# identical to shannon-loader except for the BOOT SHA-256 pin, which is the
# synthetic BOOT's (used by the black-box tests only, never installed)
$(B)/shannon-loader-testpin: $(CORE_SRC) src/sl_main.c $(HDRS) $(B)/mkfixtures
	$(CC) $(CF) -DSL_TEST_BOOT_SHA256_HEX='"'"$$($(B)/mkfixtures --print-boot-sha256)"'"' \
		$(CORE_SRC) src/sl_main.c -o $@

TEST_BINS := $(B)/shannon-loader $(B)/shannon-loader-testpin $(B)/mkfixtures \
             $(B)/test_loader $(B)/test_loader_asan $(B)/test_hashes \
             $(B)/nv_guard.so $(B)/guard_selftest

test: $(TEST_BINS)
	sh tests/run_tests.sh $(B) $(FIXDIR)

# --- ARMv7 hard-float, static ---------------------------------------------

$(X)/obj/%.o: src/%.c $(HDRS)
	@mkdir -p $(@D)
	$(CROSS_CC) $(CF) -c $< -o $@

build/shannon-loader-armv7: $(XOBJ)
	$(CROSS_CC) $(CF) -static $^ -o $@

cross: build/shannon-loader-armv7
	sh tests/safety_check.sh $(X) $(CROSS_OBJDUMP)
	@if command -v file >/dev/null 2>&1; then file $<; else readelf -h $< | grep -E 'Class|Machine|Type'; readelf -A $< | grep -E 'Tag_CPU_arch:|Tag_ABI_VFP_args'; fi

# --- containers (from macOS) ----------------------------------------------

docker-test:
	docker run --rm --platform linux/arm64 -v $(CURDIR)/..:/w -w /w/loader t715-kbuild make test

docker-cross:
	docker run --rm -v $(CURDIR)/..:/w -w /w/loader t715-omarchy:dev-armv7h \
		make cross CROSS_CC=gcc CROSS_OBJDUMP=objdump

clean:
	rm -rf build
