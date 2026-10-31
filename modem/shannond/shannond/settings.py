"""What the user chose and the CP forgets: the LTE attach APN and the technologies.

A small JSON file, /var/lib/shannond/settings.json, mode 0600: an APN may come
with a password. Losing it costs nothing but that choice, so a read or write
error is logged and shannond carries on. Nothing here is NV or EFS.
"""
import json
import logging
import os

log = logging.getLogger("shannond.settings")


class Settings:
    def __init__(self, path):
        self.path = path
        self.values = {}
        try:
            with open(path) as f:
                values = json.load(f)
            if isinstance(values, dict):
                self.values = values
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as exc:
            log.warning("settings not read: %s", exc)

    def get(self, key, default=None):
        return self.values.get(key, default)

    def save(self, **changes):
        self.values.update(changes)
        tmp = self.path + ".new"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(self.values, f)
            os.replace(tmp, self.path)
        except OSError as exc:
            log.warning("settings not saved: %s", exc)
