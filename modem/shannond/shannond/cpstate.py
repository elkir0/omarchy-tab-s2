# SPDX-License-Identifier: GPL-2.0-or-later
"""Loader session file (/run/shannon/cp-state): ``session=N state=...``.

The loader keeps umts_ipc0/umts_rfs0 open across CP restarts and publishes a
session number and the CP state here (SYNTHESIS v2 D4, D5 restart contract).
"""

DEFAULT_PATH = "/run/shannon/cp-state"


def parse_cp_state(text):
    """Return (session: int | None, state: str | None) from 'session=N state=online'."""
    session = state = None
    for token in text.replace(",", " ").split():
        key, sep, value = token.partition("=")
        if not sep:
            continue
        if key == "session":
            try:
                session = int(value)
            except ValueError:
                session = None
        elif key == "state":
            state = value.strip().lower()
    return session, state


def read_cp_state(path):
    if not path:
        return None, None
    try:
        with open(path, "r", encoding="ascii", errors="replace") as f:
            return parse_cp_state(f.read(256))
    except OSError:
        return None, None
