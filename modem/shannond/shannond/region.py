"""The region omatel reads national numbers with, from the line's own number.

Omatel falls back on the locale, while a line's calling code can differ from the
locale's country: contacts written in national form then get no
name and one conversation splits in two. The own number settles it. Only an empty
setting is filled: what the owner chose in Messages stays.
"""
import os
import re

# Calling code to libphonenumber's main region, longest prefix first. A line
# from elsewhere keeps the locale's region.
_CODES = {
    "262": "RE", "352": "LU", "377": "MC", "590": "GP", "594": "GF", "596": "MQ",
    "687": "NC", "689": "PF", "32": "BE", "33": "FR", "34": "ES", "39": "IT",
    "41": "CH", "44": "GB", "49": "DE", "1": "US",
}
_REGION_LINE = re.compile(r'^region\s*=\s*"(.*)"\s*$')


def region_of(number):
    digits = re.sub(r"[^0-9+]", "", number or "")
    if not digits.startswith("+"):
        return None
    digits = digits[1:]
    for length in (3, 2, 1):
        region = _CODES.get(digits[:length])
        if region:
            return region
    return None


def settings_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "omatel", "settings.toml")


def fill(number, path=None):
    """Write the number's region into omatel's settings if none is set.

    True once there is nothing left to do, False when the number gives no region.
    """
    path = path or settings_path()
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = []
    for i, line in enumerate(lines):
        match = _REGION_LINE.match(line)
        if match and match.group(1):
            return True
        if match:
            del lines[i]
            break
    region = region_of(number)
    if region is None:
        return False
    # A top-level key has to stay above any table in the file.
    lines.insert(0, 'region = "%s"' % region)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".new"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)
    return True
