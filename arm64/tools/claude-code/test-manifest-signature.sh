#!/usr/bin/env bash
# test-manifest-signature.sh — exercise the installer's manifest signature
# check (lib/manifest-verify.sh) against a throwaway GPG key, without any
# network access and without touching the running user's keyring.
#
# What it does:
#   - creates two throwaway keys ("pinned" and "other") in a temporary
#     GNUPGHOME (never the user's: the test exports the public keys to files);
#   - signs a fake manifest.json with the pinned key, then calls
#     verify_manifest_signature — the very function the patched installer
#     calls — with the throwaway key file and fingerprint as its two extra
#     arguments (the installer passes none: it uses Anthropic's constant) for:
#       (a) a good signature from the pinned key      → accepted
#       (b) a tampered manifest                       → refused
#       (c) a signature made by another key           → refused
#       (d) no signature file at all                  → refused
#       (e) the installer's two-argument call, with the environment trying
#           to substitute the throwaway key           → refused
#   - and checks the real shipped key one last time: anth-release-key.gpg's
#       fingerprint must be Anthropic's
#       31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
#     (the one https://downloads.claude.ai/keys/claude-code.asc publishes).
#
# Usage:
#   test-manifest-signature.sh [-h|--help]
#
# Runs on macOS (and Linux) with gpg installed. Exit status: 0 = all checks
# passed, 1 = a check failed. Everything it creates is under a mktemp -d
# removed on exit.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_LIB="$SCRIPT_DIR/manifest-verify.sh"
SHIPPED_KEY="$SCRIPT_DIR/anth-release-key.gpg"
ANTHROPIC_FP=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

case "${1:-}" in
  -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
  "") ;;
  *) printf 'test-manifest-signature.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

fail=0
say()  { printf 'ok   %s\n' "$*"; }
nope() { printf 'FAIL %s\n' "$*" >&2; fail=1; }

command -v gpg >/dev/null 2>&1 || { printf 'gpg is required\n' >&2; exit 2; }
[ -f "$VERIFY_LIB" ] || { printf 'no %s\n' "$VERIFY_LIB" >&2; exit 2; }
[ -f "$SHIPPED_KEY" ] || { printf 'no %s\n' "$SHIPPED_KEY" >&2; exit 2; }

work="$(mktemp -d)" || exit 2
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"

# The throwaway keys. No passphrases: --pinentry-mode loopback takes the empty
# one gpg --batch --quick-gen-key generates with.
gen_key() { # $1 uid
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-gen-key "$1" rsa2048 sign 2>/dev/null
}
gen_key 'Test Pinned <pinned@test>'  || { printf 'cannot create the pinned test key\n' >&2; exit 2; }
gen_key 'Test Other <other@test>'    || { printf 'cannot create the other test key\n' >&2; exit 2; }

# The library only reads files: export each public key to its own file, the
# way the package ships Anthropic's, and pin the fingerprint of the "pinned"
# one through the same environment variable the test is the only one to set.
gpg --batch --quiet --export --armor 'Test Pinned' > "$work/pinned.asc" 2>/dev/null
gpg --batch --quiet --export --armor 'Test Other'  > "$work/other.asc"  2>/dev/null
PINNED_FP="$(gpg --batch --list-keys --with-colons 'Test Pinned' 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
[ -n "$PINNED_FP" ] || { printf 'cannot read the pinned test key fingerprint\n' >&2; exit 2; }

printf '%s\n' '{"platforms":{"linux-arm64-musl":{"checksum":"fake"}}}' > "$work/manifest.json"

sign_with() { # $1 key selector, $2 output .sig
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --local-user "$1" --detach-sign --output "$2" "$work/manifest.json" 2>/dev/null
}
sign_with 'Test Pinned' "$work/good.sig"     # (a), (b)
sign_with 'Test Other'  "$work/wrong-key.sig"  # (c)

# The library under test: called with two arguments it uses Anthropic's
# fingerprint (a constant) and the installer's key directory; the test passes
# its throwaway key file and fingerprint as the two extra arguments instead.
run_verify() { # $1 manifest, $2 sig [$3 key file] → 0 accepted, 1 refused
  ( sh -c '. "$1" && verify_manifest_signature "$2" "$3" "$4" "$5"' \
      _ "$VERIFY_LIB" "$1" "$2" "${3:-$work/pinned.asc}" "$PINNED_FP" ) >/dev/null 2>&1
}

# (a) a good signature from the pinned key: accepted.
if run_verify "$work/manifest.json" "$work/good.sig"; then
  say '(a) good signature from the pinned key: accepted'
else
  nope '(a) a good signature from the pinned key was refused'
fi

# (b) a tampered manifest: the signature was made over other bytes: refused.
printf '%s\n' '{"platforms":{"linux-arm64-musl":{"checksum":"TAMPERED"}}}' > "$work/tampered.json"
if run_verify "$work/tampered.json" "$work/good.sig"; then
  nope '(b) a tampered manifest was accepted'
else
  say '(b) tampered manifest: refused'
fi

# (c) a signature from another key: good signature, wrong key: refused.
if run_verify "$work/manifest.json" "$work/wrong-key.sig"; then
  nope '(c) a signature from another key was accepted'
else
  say '(c) signature from another key: refused'
fi

# (c, bis) the wrong key smuggled into the keyring file: the fingerprint
# comparison is what must catch it (the signature itself is valid).
if run_verify "$work/manifest.json" "$work/wrong-key.sig" "$work/other.asc"; then
  nope '(c) another key matching its own signature was accepted'
else
  say '(c) another key with a valid self-signature: refused (fingerprint pin)'
fi

# (e) the installer's own two-argument call cannot be redirected by the
# environment: variables naming the throwaway key and fingerprint are ignored,
# the shipped Anthropic key is used, and the throwaway signature is refused.
if ( CLAUDE_SIGNING_KEY_FP="$PINNED_FP" CLAUDE_SIGNING_KEY_FILE="$work/pinned.asc" \
     CLAUDE_SIGNING_KEY_DIR="$(dirname "$VERIFY_LIB")" \
     sh -c '. "$1" && verify_manifest_signature "$2" "$3"' \
     _ "$VERIFY_LIB" "$work/manifest.json" "$work/good.sig" ) >/dev/null 2>&1; then
  nope '(e) the environment redirected the installer to another key'
else
  say '(e) environment cannot substitute the key or fingerprint: refused'
fi

# (d) no signature file at all: refused.
if run_verify "$work/manifest.json" "$work/absent.sig"; then
  nope '(d) a missing signature was accepted'
else
  say '(d) missing signature: refused'
fi

# The shipped key: whatever is in anth-release-key.gpg must be the key
# Anthropic publishes — not any key a build could have swapped in.
shipped_fp="$(gpg --batch --show-keys --with-colons "$SHIPPED_KEY" 2>/dev/null \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
if [ "$shipped_fp" = "$ANTHROPIC_FP" ]; then
  say "shipped anth-release-key.gpg is Anthropic's key ($ANTHROPIC_FP)"
else
  nope "shipped anth-release-key.gpg has fingerprint ${shipped_fp:-none}, want $ANTHROPIC_FP"
fi

if [ "$fail" -eq 0 ]; then
  printf 'test-manifest-signature.sh: all checks passed\n'
else
  printf 'test-manifest-signature.sh: FAILED\n' >&2
fi
exit "$fail"
