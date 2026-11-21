#!/usr/bin/env python3
"""Preloaded Waydroid launcher daemon for the SM-T715.

`waydroid app launch PKG` is a Python program (~1.1 s start-up with all cores
online, ~2.3 s with big cores offline, more under memory pressure). This daemon
imports Waydroid's Python modules once at session start, listens on
`$XDG_RUNTIME_DIR/t715-android/launch.fifo`, and forks a child per accepted
request to invoke `tools.main()` directly with `sys.argv = ["waydroid"] + args`.

Only `app launch PKG`, `app intent ACTION URI`, and `show-full-ui` are accepted;
anything else is logged and dropped. Exits 3 if Waydroid's modules cannot be
imported (so the systemd user unit stays failed and `/usr/local/bin/waydroid`
falls back to `/usr/bin/waydroid`).

Environment hooks:
  T715_ANDROID_WAYDROID_LIB  Waydroid Python library dir (default: /usr/lib/waydroid)
  XDG_RUNTIME_DIR            Per-user runtime directory for FIFO and pid file
"""

import errno
import os
import select
import shlex
import signal
import sys
import traceback

MAX_LINE_BYTES = 65536


def log_err(msg: str) -> None:
    print(f"t715-android-launchd: {msg}", file=sys.stderr, flush=True)


def is_accepted(argv: list) -> bool:
    if len(argv) == 1 and argv[0] == "show-full-ui":
        return True
    if (
        len(argv) == 3
        and argv[0] == "app"
        and argv[1] == "launch"
        and argv[2]
        and not argv[2].startswith("-")
    ):
        return True
    if (
        len(argv) == 4
        and argv[0] == "app"
        and argv[1] == "intent"
        and argv[2]
        and not argv[2].startswith("-")
        and argv[3]
    ):
        return True
    return False


def reap_children() -> None:
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if pid <= 0:
            break


def write_pid_file(pid_path: str) -> None:
    tmp_path = f"{pid_path}.{os.getpid()}.tmp"
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, f"{os.getpid()}\n".encode("ascii"))
    finally:
        os.close(fd)
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, pid_path)


def main() -> int:
    waydroid_lib = os.environ.get("T715_ANDROID_WAYDROID_LIB") or "/usr/lib/waydroid"
    sys.path.insert(0, waydroid_lib)
    try:
        import tools  # noqa: F401
        import tools.actions  # noqa: F401
        import tools.actions.app_manager  # noqa: F401
        import tools.interfaces.IPlatform  # noqa: F401
    except Exception as exc:
        log_err(f"failed to import Waydroid modules from {waydroid_lib}: {exc}")
        return 3

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        log_err("XDG_RUNTIME_DIR is not set")
        return 1

    run_dir = os.path.join(runtime_dir, "t715-android")
    fifo_path = os.path.join(run_dir, "launch.fifo")
    pid_path = os.path.join(run_dir, "launchd.pid")

    os.makedirs(run_dir, mode=0o700, exist_ok=True)
    os.chmod(run_dir, 0o700)

    try:
        os.unlink(fifo_path)
    except FileNotFoundError:
        pass
    os.mkfifo(fifo_path, 0o600)
    os.chmod(fifo_path, 0o600)

    rfd = -1
    wfd = -1
    wake_r = -1
    wake_w = -1
    stop_requested = False

    def handle_stop(_signum, _frame):
        nonlocal stop_requested
        stop_requested = True

    def handle_sigchld(_signum, _frame):
        pass

    try:
        # Keep both ends open in the parent so rapid writers never trigger
        # spurious EOFs and writers never block waiting for the reader open.
        rfd = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
        wfd = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)

        wake_r, wake_w = os.pipe()
        os.set_blocking(wake_r, False)
        os.set_blocking(wake_w, False)

        signal.signal(signal.SIGTERM, handle_stop)
        signal.signal(signal.SIGINT, handle_stop)
        signal.signal(signal.SIGCHLD, handle_sigchld)
        signal.set_wakeup_fd(wake_w, warn_on_full_buffer=False)

        write_pid_file(pid_path)

        buf = bytearray()
        while not stop_requested:
            try:
                readable, _, _ = select.select([rfd, wake_r], [], [])
            except InterruptedError:
                continue
            except OSError as exc:
                if exc.errno == errno.EINTR:
                    continue
                raise

            if wake_r in readable:
                while True:
                    try:
                        chunk = os.read(wake_r, 4096)
                        if not chunk:
                            break
                    except BlockingIOError:
                        break
                reap_children()
                if stop_requested:
                    break

            if rfd in readable:
                while True:
                    try:
                        data = os.read(rfd, 4096)
                    except BlockingIOError:
                        break
                    if not data:
                        break
                    buf.extend(data)
                    if len(buf) > MAX_LINE_BYTES and b"\n" not in buf:
                        log_err("dropping oversized line")
                        buf.clear()
                        continue
                    while True:
                        nl = buf.find(b"\n")
                        if nl < 0:
                            break
                        raw = bytes(buf[:nl])
                        del buf[: nl + 1]
                        line = raw.decode("utf-8", errors="replace").strip()
                        if not line:
                            continue
                        try:
                            argv = shlex.split(line)
                        except ValueError as exc:
                            log_err(f"dropping malformed request ({exc}): {line!r}")
                            continue
                        if not argv:
                            continue
                        if not is_accepted(argv):
                            log_err(f"dropping unsupported request: {argv!r}")
                            continue

                        sys.stdout.flush()
                        sys.stderr.flush()
                        pid = os.fork()
                        if pid == 0:
                            code = 1
                            try:
                                signal.set_wakeup_fd(-1)
                                signal.signal(signal.SIGTERM, signal.SIG_DFL)
                                signal.signal(signal.SIGINT, signal.SIG_DFL)
                                signal.signal(signal.SIGCHLD, signal.SIG_DFL)
                                for fd in (rfd, wfd, wake_r, wake_w):
                                    if fd >= 0:
                                        try:
                                            os.close(fd)
                                        except OSError:
                                            pass
                                devnull = os.open(os.devnull, os.O_RDONLY)
                                try:
                                    os.dup2(devnull, 0)
                                finally:
                                    if devnull != 0:
                                        os.close(devnull)
                                sys.argv = ["waydroid"] + argv
                                os.umask(0o022)
                                rc = tools.main()
                                code = rc if isinstance(rc, int) else 0
                            except SystemExit as exc:
                                if exc.code is None:
                                    code = 0
                                elif isinstance(exc.code, int):
                                    code = exc.code
                                else:
                                    print(exc.code, file=sys.stderr, flush=True)
                                    code = 1
                            except BaseException:
                                traceback.print_exc(file=sys.stderr)
                                code = 1
                            finally:
                                try:
                                    sys.stdout.flush()
                                    sys.stderr.flush()
                                except Exception:
                                    pass
                                os._exit(code)
            reap_children()
    finally:
        try:
            signal.set_wakeup_fd(-1)
        except Exception:
            pass
        for fd in (rfd, wfd, wake_r, wake_w):
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
        for path in (fifo_path, pid_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            except OSError:
                pass
        reap_children()

    return 0


if __name__ == "__main__":
    sys.exit(main())
