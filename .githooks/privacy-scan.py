#!/usr/bin/env python3
"""Refuse text that would publish something personal.

  privacy-scan.py --staged         the lines and paths a commit adds (pre-commit)
  privacy-scan.py --message FILE   a commit message (commit-msg)
  privacy-scan.py --pre-push       every commit a push sends: its author and
                                   committer (elkir0, noreply), its dates (a day
                                   at 12:00:00 +0000), its message and diff
  privacy-scan.py < TEXT           lines, each optionally "LABEL\\0text"

Exits 1 on a match. A match prints its kind and where, never the value.

Two kinds of check:
- generic, in this file: an OAuth token, a private key, a coordinate pair, a
  macOS home path, a run of 14 to 16 digits (an IMEI, an ICCID);
- private, from the owner's lists outside the repository
  ($T715_PRIVATE_DIR, ~/dev/sm-t715-private by default): the identifiers of
  the tablet and its owner, in the forms they take in dumps and logs. Without
  the lists only the generic checks run, and a note says so.

privacy/known-public.sha256 lists, by hash, the private forms that
the published repository already carries (common words, mostly): they are
not checked. .githooks/privacy-scan.py --refresh-known PUBLISHED_TREE
rewrites it.
"""
import hashlib, os, re, subprocess, sys

PRIV = os.environ.get('T715_PRIVATE_DIR', os.path.expanduser('~/dev/sm-t715-private'))
LISTS = (('identifier', 'privacy/identifiers.txt', None),
         ('Wi-Fi address', 'privacy/wifi-addr', None),
         (None, 'privacy/blacklist.tsv', '\t'))
KNOWN = os.path.join(PRIV, 'privacy/known-public.sha256')

GENERIC = (
    ('OAuth token', re.compile(r'sk-ant-[A-Za-z0-9]+-[A-Za-z0-9_-]{20,}')),
    ('private key', re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')),
    ('coordinates', re.compile(r'(?<![\d.])-?\d{1,2}\.\d{4,}\s*[,;]\s*-?\d{1,3}\.\d{4,}(?![\d.])')),
    ('macOS home path', re.compile(r'/Users/[A-Za-z][A-Za-z0-9._-]*/')),
    ('14-16 digit number', re.compile(r'(?<![0-9A-Za-z])\d{14,16}(?![0-9A-Za-z])')),
)


def forms(value):
    """The forms a value takes in dumps and logs (as the publication audit's scan)."""
    v = value.replace('\x00', '').strip()
    out = set()
    if len(v) < 4:
        return out
    low = v.lower()
    out.add(low)
    if re.fullmatch(r'([0-9a-f]{2}[:-]){5}[0-9a-f]{2}', low):
        b = re.split('[:-]', low)
        for x in (b, b[::-1]):
            for sep in (':', '-', '', ' ', '_'):
                out.add(sep.join(x))
            out.add(', '.join('0x' + y for y in x))
    d = re.sub(r'\D', '', v)
    if v.strip('+ ').replace(' ', '').isdigit() and len(d) >= 7:
        out.add(d)
        out.add(' '.join(d[i:i + 2] for i in range(0, len(d), 2)))
        s = d + ('f' if len(d) % 2 else '')
        out.add(''.join(s[i + 1] + s[i] for i in range(0, len(s), 2)))
    else:
        out.add(v.encode().hex())
    return {f for f in out if len(f) >= 5}


def needles():
    found, missing = {}, []
    for kind, rel, sep in LISTS:
        path = os.path.join(PRIV, rel)
        try:
            lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
        except OSError:
            missing.append(rel)
            continue
        for l in lines:
            if not l.strip():
                continue
            k, v = (l.split(sep, 1) if sep and sep in l else (kind or 'private', l))
            for f in forms(v):
                found.setdefault(f, kind or k)
    try:
        known = set(open(KNOWN).read().split())
    except OSError:
        known = set()
    return {f: k for f, k in found.items() if hashlib.sha256(f.encode()).hexdigest() not in known}, missing


NEUTRAL = ('elkir0', 'elkir0@users.noreply.github.com')


def git(*a):
    return subprocess.run(['git', *a], capture_output=True).stdout.decode('utf-8', 'replace')


def added_lines(diff, prefix=''):
    """'LABEL\\0line' for every added line of a unified diff, and every new path."""
    out, f = [], '?'
    for l in diff.split('\n'):
        if l.startswith('+++ '):
            f = l[6:] if l.startswith('+++ b/') else l[4:]
            out.append(f'{prefix}{f} (path)\0{f}')
        elif l.startswith('+') and not l.startswith('+++'):
            out.append(f'{prefix}{f}\0{l[1:]}')
    return out


def commits_to_push(stdin):
    """The commits a push sends, from pre-push's stdin."""
    shas = []
    for l in stdin.split('\n'):
        p = l.split()
        if len(p) != 4 or set(p[1]) == {'0'}:
            continue
        rng = [p[1], '--not', '--remotes'] if set(p[3]) == {'0'} else [f'{p[3]}..{p[1]}']
        shas += git('rev-list', *rng).split()
    return shas


def main():
    if len(sys.argv) == 2 and sys.argv[1] == '--staged':
        text = added_lines(git('diff', '--cached', '--no-color', '--no-ext-diff', '-U0', '--diff-filter=ACMR'))
        return scan(text)
    if len(sys.argv) == 3 and sys.argv[1] == '--message':
        return scan(f'commit message\0{l}' for l in open(sys.argv[2], errors='replace').read().split('\n'))
    if len(sys.argv) == 2 and sys.argv[1] == '--pre-push':
        bad, lines = 0, []
        for c in commits_to_push(sys.stdin.read()):
            who = git('show', '-s', '--format=%an%n%ae%n%cn%n%ce%n%ad%n%cd', '--date=raw', c).split('\n')
            if tuple(who[0:2]) != NEUTRAL or tuple(who[2:4]) != NEUTRAL:
                print(f'privacy-scan: commit {c[:12]} is not by {NEUTRAL[0]} <{NEUTRAL[1]}>', file=sys.stderr)
                bad += 1
            for d in who[4:6]:
                secs, tz = d.split() if d else ('1', '?')
                if tz != '+0000' or int(secs) % 86400 != 43200:
                    print(f'privacy-scan: commit {c[:12]} has a date that is not a day at 12:00:00 +0000',
                          file=sys.stderr)
                    bad += 1
                    break
            lines += [f'{c[:12]} message\0{l}' for l in git('show', '-s', '--format=%B', c).split('\n')]
            lines += added_lines(git('show', '--format=', '--no-color', '--no-ext-diff', '-U0', c), f'{c[:12]} ')
        return 1 if scan(lines) or bad else 0
    if len(sys.argv) == 3 and sys.argv[1] == '--refresh-known':
        ns, _ = needles()
        hits = set()
        for d, ds, fs in os.walk(sys.argv[2]):
            ds[:] = [x for x in ds if x != '.git']
            for f in fs:
                raw = open(os.path.join(d, f), 'rb').read().decode('utf-8', 'replace')
                t = raw.lower()
                hits.update(n for n in ns if n in t)
                hits.update(m.group(0) for _, rx in GENERIC for m in rx.finditer(raw))
        with open(KNOWN, 'a') as k:
            for n in sorted(hits):
                k.write(hashlib.sha256(n.encode()).hexdigest() + '\n')
        print(f'privacy-scan: {len(hits)} forms and generic matches already public, now skipped')
        return 0
    return scan(sys.stdin.buffer.read().decode('utf-8', 'replace').split('\n'))


def scan(lines):
    ns, missing = needles()
    if missing:
        print('privacy-scan: no private lists (' + ', '.join(missing) + '), generic checks only',
              file=sys.stderr)
    pat = re.compile('|'.join(re.escape(n) for n in sorted(ns, key=len, reverse=True))) if ns else None
    try:
        known = set(open(KNOWN).read().split())
    except OSError:
        known = set()
    bad = 0
    for line in lines:
        label, _, text = line.rpartition('\0')
        for kind, rx in GENERIC:
            for m in rx.finditer(text):
                if hashlib.sha256(m.group(0).encode()).hexdigest() not in known:
                    print(f'privacy-scan: {kind} in {label or "?"}', file=sys.stderr)
                    bad += 1
                    break
        if pat:
            for m in pat.finditer(text.lower()):
                print(f'privacy-scan: {ns[m.group(0)]} in {label or "?"}', file=sys.stderr)
                bad += 1
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
