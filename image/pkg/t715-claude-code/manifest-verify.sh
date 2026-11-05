# shellcheck shell=sh
# manifest-verify.sh — fail-closed check of Anthropic's manifest.json signature. POSIX sh.
#
# Sourced by install.sh (this directory) before ANY use of the manifest: the
# sha256 the installer compares the official binary against is only worth
# trusting if the manifest it comes from is Anthropic's, so the detached
# signature (manifest.json.sig, published next to manifest.json for every
# release since 2.1.89) is verified against a throwaway keyring that holds ONLY
# the release key shipped next to this file (anth-release-key.gpg) — never the
# user's keyring, and nothing is ever imported into it.
#
# The function is standalone (no network) so it can be exercised by itself:
# the package's test-manifest-signature.sh passes a throwaway key and its
# fingerprint as arguments, with signed, tampered, wrong-key and unsigned
# fixtures.

# Anthropic's Claude Code release signing key
# (https://downloads.claude.ai/keys/claude-code.asc, documented with this
# fingerprint at https://code.claude.com/docs/en/setup):
#   31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
# A constant, never read from the environment: the installer runs as root.
CLAUDE_SIGNING_KEY_FP=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

# verify_manifest_signature MANIFEST SIG [KEYFILE FPR] — succeeds only when SIG
# is a valid detached signature of MANIFEST whose signing key's PRIMARY
# fingerprint (gpg's VALIDSIG status line, not merely the first key of the
# keyring) is the pinned one. The installer calls it with two arguments: the
# key file is anth-release-key.gpg in CLAUDE_SIGNING_KEY_DIR, which install.sh
# sets itself, and the fingerprint is the constant above. KEYFILE and FPR
# exist for test-manifest-signature.sh alone, which pins a throwaway key that
# way; nothing reads them from the environment. Prints nothing; every failure
# path returns non-zero, so the caller fails closed with its own message.
verify_manifest_signature() { # $1 manifest.json, $2 manifest.json.sig [$3 key file, $4 fingerprint]
  [ -r "$1" ] && [ -r "$2" ] || return 1
  if [ $# -ge 4 ]; then
    _mv_key=$3; _mv_want=$4
  else
    [ -n "${CLAUDE_SIGNING_KEY_DIR:-}" ] || return 1
    _mv_key="$CLAUDE_SIGNING_KEY_DIR/anth-release-key.gpg"; _mv_want=$CLAUDE_SIGNING_KEY_FP
  fi
  [ -r "$_mv_key" ] && [ -n "$_mv_want" ] || return 1
  command -v gpg >/dev/null 2>&1 || return 1
  _mv_keyring="$(mktemp -d)" || return 1
  _mv_rc=0
  gpg --homedir "$_mv_keyring" --batch --quiet --no-default-keyring \
      --import "$_mv_key" >/dev/null 2>&1 || _mv_rc=1
  if [ "$_mv_rc" -eq 0 ]; then
    # A good signature from a key in that keyring (a bad digest, a missing
    # signature or an unknown key fail here), and exactly one VALIDSIG line
    # whose last field, the signing key's primary fingerprint, is the pin.
    _mv_valid="$(gpg --homedir "$_mv_keyring" --batch --quiet --no-default-keyring \
        --status-fd 1 --verify "$2" "$1" 2>/dev/null | awk '$2 == "VALIDSIG" { print $NF }')" \
        || _mv_rc=1
    if [ "$_mv_rc" -eq 0 ]; then
      [ "$_mv_valid" = "$_mv_want" ] || _mv_rc=1
    fi
  fi
  rm -rf "$_mv_keyring"
  return "$_mv_rc"
}
