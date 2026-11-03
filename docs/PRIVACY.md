# Keeping the repository publishable

This repository is public, and it is the one the work happens in. What would identify or
locate the person whose tablet it is never enters it:

- the tablet's dumps, backups and Samsung files (EFS, NV data, firmware, blobs), its
  identifiers (IMEI, IMSI, ICCID, serial number, MAC addresses), network names, passwords,
  phone numbers, SMS, positions and GPS traces;
- the dated working journals and research in progress (`docs/journal/README.md`);
- personal settings: the SSH key, language, time zone and keyboard of one's own image are
  build options (`image/tools/build-rootfs --ssh-pubkey --locale --timezone --keyboard`,
  `docs/DEPLOY.md`), passed from a script kept outside the repository.

## The hooks

```bash
git config core.hooksPath .githooks
```

- `pre-commit` and `commit-msg` refuse a commit that adds a token, a private key, a
  coordinate pair, a macOS home path or a 14-16 digit number, or one of the identifiers the
  private lists hold, in the forms they take in dumps and logs.
- `post-commit` gives every commit the published identity and a date without a time of day:
  `elkir0 <elkir0@users.noreply.github.com>`, its day at 12:00:00 +0000. Rebase with
  `--committer-date-is-author-date`.
- `pre-push` refuses a push that would send a commit with another identity, a time of day, or
  something the checks above refuse, in its message or its diff.

The private lists live outside the repository, in `$T715_PRIVATE_DIR/privacy/`
(`~/dev/sm-t715-private/privacy/` by default): `identifiers.txt`, `wifi-addr`,
`blacklist.tsv` (category, tab, value) and `known-public.sha256`, the hashes of the matches
the published tree already carries (common words and synthetic test values), which are not
checked again. Without the lists the hooks run the generic checks only, and say so. A match
is reported by its kind and its file, never by its value.

The hooks catch values and patterns, not prose: before a release, the new text is still read
for what no pattern sees, such as a place, a habit or a time of day.
