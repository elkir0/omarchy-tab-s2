#!/usr/bin/env python3
# Host test for the keyboard-picker patch of the omarchy-tab-s2 arm64 image
# (arm64/rootfs/patches-omarchy-settings/0001-keyboard-layouts-without-fcitx5.patch).
#
# Omarchy 4.5's typing_setup.save_keyboard() first asks fcitx5 for its input
# group (fcitx5-remote -q) and only then writes keyboard-layouts, reloads
# Hyprland and checks the live layout. The image keeps fcitx5 off, so that
# first question fails and the picker saves nothing. The patch skips the
# fcitx5 round-trip when no fcitx5 of this user runs (pgrep -x fcitx5).
#
# This test extracts usr/share/omarchy/default/input-methods from the pinned
# omarchy-settings package (arm64/rootfs/omarchy-pins) into a pristine and a
# patched tree, applies every patch of the patches directory, and runs
# save_keyboard() in a subprocess against stub hyprctl/pgrep/fcitx5-remote/
# busctl commands that log every call. Python 3 stdlib only:
#   python3 -I arm64/rootfs/tests/test_keyboard_picker.py

import ast
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[3]
ROOTFS = REPO / "arm64" / "rootfs"
INPUT_METHODS = Path("usr/share/omarchy/default/input-methods")

failures = 0


def check(what, ok, detail=""):
    global failures
    if not ok:
        failures += 1
    print(("ok - " if ok else "not ok - ") + what + ("" if ok else ": " + str(detail)))


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pinned_package():
    """The omarchy-settings file pinned by arm64/rootfs/omarchy-pins, or None."""
    filename = digest = None
    for line in (ROOTFS / "omarchy-pins").read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 3 and fields[0] == "omarchy-settings":
            filename, digest = fields[1], fields[2]
            break
    if not filename:
        return None
    candidates = []
    env_pkg = os.environ.get("OMARCHY_SETTINGS_PKG")
    if env_pkg:
        candidates.append(Path(env_pkg))
    caches = [ROOTFS / "cache/omarchy-aarch64"]
    if os.environ.get("T715_OMARCHY_CACHE"):
        caches.append(Path(os.environ["T715_OMARCHY_CACHE"]))
    caches += [Path.home() / "dev/omarchy-tab-s2/image/cache/omarchy-upstream/stable/aarch64",
               Path.home() / "dev/Lenovomarchy/cache/omarchy-upstream/stable/aarch64"]
    candidates += [directory / filename for directory in caches]
    for candidate in candidates:
        if candidate.is_file() and sha256_file(candidate) == digest:
            return candidate
    return None


# Stub commands, put first on PATH of the scenario subprocesses. Each appends
# its argv as one line to the calls log (env KB_CALLS).
STUBS = {
    "hyprctl": '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
log = os.environ.get("KB_CALLS")
if log:
    with open(log, "a") as fh:
        fh.write("hyprctl " + " ".join(args) + "\\n")
if "configerrors" in args:
    if os.environ.get("KB_ERRORS_AFTER_RELOAD") == "1" and log and os.path.exists(log):
        with open(log) as fh:
            if any(line.rstrip("\\n") == "hyprctl reload" for line in fh):
                print("error: bad layout")
elif "reload" in args:
    pass
else:
    layout, variant = "us", ""
    config_home = os.environ.get("XDG_CONFIG_HOME")
    if config_home:
        try:
            with open(os.path.join(config_home, "omarchy", "keyboard-layouts")) as fh:
                for line in fh:
                    if line.startswith("XKBLAYOUT="):
                        layout = line.split("=", 1)[1].strip()
                    elif line.startswith("XKBVARIANT="):
                        variant = line.split("=", 1)[1].strip()
        except OSError:
            pass
    if "input:kb_layout" in args:
        print(json.dumps({"str": layout}))
    elif "input:kb_variant" in args:
        print(json.dumps({"str": variant}))
''',
    "pgrep": '''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
log = os.environ.get("KB_CALLS")
if log:
    with open(log, "a") as fh:
        fh.write("pgrep " + " ".join(args) + "\\n")
sys.exit(0 if os.environ.get("KB_FCITX_RUNNING") == "1" else 1)
''',
    "fcitx5-remote": '''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
log = os.environ.get("KB_CALLS")
if log:
    with open(log, "a") as fh:
        fh.write("fcitx5-remote " + " ".join(args) + "\\n")
print("Failed to get reply.", file=sys.stderr)
sys.exit(1)
''',
    "busctl": '''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
log = os.environ.get("KB_CALLS")
if log:
    with open(log, "a") as fh:
        fh.write("busctl " + " ".join(args) + "\\n")
sys.exit(1)
''',
    "omarchy-i18n": '''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
log = os.environ.get("KB_CALLS")
if log:
    with open(log, "a") as fh:
        fh.write("omarchy-i18n " + " ".join(args) + "\\n")
print("Keyboard Layouts Failed" if "keyboardLayoutsFailed" in args else "Input Methods Failed")
''',
    "omarchy-notification-send": '''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
log = os.environ.get("KB_CALLS")
if log:
    with open(log, "a") as fh:
        fh.write("omarchy-notification-send " + " ".join(args) + "\\n")
''',
}


def exception_type(stderr):
    """The exception type named on the last line of a Python traceback."""
    lines = [line.strip() for line in stderr.strip().splitlines() if line.strip()]
    if not lines:
        return ""
    return lines[-1].split(":", 1)[0].strip().split(".")[-1]


def failure_detail(result):
    """One-line detail for a failed scenario subprocess."""
    lines = [line.strip() for line in result.stderr.strip().splitlines() if line.strip()]
    last = lines[-1] if lines else ""
    return f"exit {result.returncode}, {exception_type(result.stderr) or 'no exception'}: {last[:160]}"


def run_scenario(work, tree, selected, extra_env=None, existing=None):
    """Run typing_setup.save_keyboard(selected) in a subprocess of `tree`.

    Fresh HOME and XDG_CONFIG_HOME, stub bin first on PATH, calls logged to
    KB_CALLS. Returns (CompletedProcess, layout file path, calls log path).
    """
    home = Path(tempfile.mkdtemp(dir=work))
    config_home = home / "config"
    (config_home / "omarchy").mkdir(parents=True)
    if existing is not None:
        (config_home / "omarchy" / "keyboard-layouts").write_text(existing)
    calls = home / "calls.log"
    calls.write_text("")
    env = dict(os.environ)
    env.update({
        "PATH": str(work / "bin") + os.pathsep + env.get("PATH", ""),
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(config_home),
        "KB_CALLS": str(calls),
        "OMARCHY_PATH": str(tree / "usr/share/omarchy"),
    })
    for name in ("KB_FCITX_RUNNING", "KB_ERRORS_AFTER_RELOAD"):
        env.pop(name, None)
    env.update(extra_env or {})
    directory = str(tree / INPUT_METHODS)
    code = ("import sys; sys.path.insert(0, " + repr(directory) + "); "
            "import typing_setup; typing_setup.save_keyboard(" + repr(selected) + ")")
    result = subprocess.run([sys.executable, "-I", "-c", code],
                            env=env, capture_output=True, text=True)
    return result, config_home / "omarchy" / "keyboard-layouts", calls


def logged_calls(calls):
    return calls.read_text().splitlines() if calls.exists() else []


def no_fcitx_calls(lines):
    return not any(line.startswith(("fcitx5-remote", "busctl")) for line in lines)


def main():
    pkg = pinned_package()
    if pkg is None:
        print("ok - keyboard picker # SKIP no pinned omarchy-settings package")
        return 0
    if shutil.which("bsdtar") is None or shutil.which("patch") is None:
        print("ok - keyboard picker # SKIP bsdtar or patch missing")
        return 0

    work = Path(tempfile.mkdtemp(prefix="keyboard-picker-test-"))
    try:
        trees = {}
        for name in ("pristine", "patched"):
            root = work / name
            root.mkdir()
            extract = subprocess.run(
                ["bsdtar", "-xf", str(pkg), "-C", str(root), INPUT_METHODS.as_posix()],
                capture_output=True, text=True)
            check(f"{name} tree extracts {INPUT_METHODS}", extract.returncode == 0,
                  (extract.stdout + extract.stderr).strip())
            trees[name] = root
        pristine, patched = trees["pristine"], trees["patched"]

        patches_dir = Path(os.environ.get("KB_TEST_PATCHES_DIR")
                           or ROOTFS / "patches-omarchy-settings")
        patch_files = sorted(patches_dir.glob("*.patch")) if patches_dir.is_dir() else []
        for patch_file in patch_files:
            applied = subprocess.run(
                ["patch", "--forward", "--fuzz=0", "-p1",
                 "-d", str(patched / "usr/share/omarchy"), "-i", str(patch_file.resolve())],
                capture_output=True, text=True)
            check(f"patch {patch_file.name} applies", applied.returncode == 0,
                  (applied.stdout + applied.stderr).strip())
        try:
            ast.parse((patched / INPUT_METHODS / "typing_setup.py").read_text())
            check("patched typing_setup.py parses", True)
        except SyntaxError as error:
            check("patched typing_setup.py parses", False, error)

        bin_dir = work / "bin"
        bin_dir.mkdir()
        for name, body in STUBS.items():
            stub = bin_dir / name
            stub.write_text(body)
            stub.chmod(0o755)

        # 1. patched, fcitx5 off, ["fr"]: saves, reloads, checks, no fcitx5.
        result, layout, calls = run_scenario(work, patched, ["fr"])
        check("s1 patched, fcitx5 off, [fr] succeeds", result.returncode == 0,
              failure_detail(result))
        content = layout.read_text() if layout.exists() else None
        check("s1 layout file is exactly XKBLAYOUT=fr/XKBVARIANT=",
              content == "XKBLAYOUT=fr\nXKBVARIANT=\n", repr(content))
        lines = logged_calls(calls)
        check("s1 hyprctl reload was called", "hyprctl reload" in lines, repr(lines))
        check("s1 no fcitx5-remote or busctl call", no_fcitx_calls(lines), repr(lines))

        # 2. patched, fcitx5 off, ["fr", "us"]: a two-layout selection.
        result, layout, calls = run_scenario(work, patched, ["fr", "us"])
        check("s2 patched, fcitx5 off, [fr, us] succeeds", result.returncode == 0,
              failure_detail(result))
        lines = layout.read_text().splitlines() if layout.exists() else []
        check("s2 layout file starts with XKBLAYOUT=fr,us", lines[:1] == ["XKBLAYOUT=fr,us"],
              repr(lines[:1]))
        lines = logged_calls(calls)
        check("s2 no fcitx5-remote or busctl call", no_fcitx_calls(lines), repr(lines))

        # 3. patched, fcitx5 off, reload introduces a config error: fails and
        #    restores the previous layout file.
        result, layout, calls = run_scenario(
            work, patched, ["fr"], extra_env={"KB_ERRORS_AFTER_RELOAD": "1"},
            existing="XKBLAYOUT=de\nXKBVARIANT=\n")
        check("s3 patched, fcitx5 off, reload error fails with RuntimeError",
              result.returncode != 0 and exception_type(result.stderr) == "RuntimeError",
              f"exit {result.returncode}, {exception_type(result.stderr) or 'no exception'}")
        content = layout.read_text() if layout.exists() else None
        check("s3 layout file restored to the de content",
              content == "XKBLAYOUT=de\nXKBVARIANT=\n", repr(content))

        # 4. patched, fcitx5 running: Omarchy's own path still asks fcitx5
        #    first, so the pick fails and nothing is saved.
        result, layout, calls = run_scenario(work, patched, ["fr"],
                                             extra_env={"KB_FCITX_RUNNING": "1"})
        check("s4 patched, fcitx5 running, [fr] fails with CalledProcessError",
              result.returncode != 0 and exception_type(result.stderr) == "CalledProcessError",
              f"exit {result.returncode}, {exception_type(result.stderr) or 'no exception'}")
        check("s4 no layout file created", not layout.exists(), "file exists")

        # 5. pristine, fcitx5 off: the bug the patch fixes — the fcitx5 query
        #    fails before anything is saved.
        result, layout, calls = run_scenario(work, pristine, ["fr"])
        check("s5 pristine, fcitx5 off, [fr] fails with CalledProcessError (the bug)",
              result.returncode != 0 and exception_type(result.stderr) == "CalledProcessError",
              f"exit {result.returncode}, {exception_type(result.stderr) or 'no exception'}")
        check("s5 no layout file created", not layout.exists(), "file exists")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
