# SPDX-License-Identifier: GPL-2.0-or-later
"""Event-loop abstraction for shannond.

The core is written against a tiny callback interface so that it can run on

* ``SelectorLoop`` - stdlib only (``select.poll``), the default for the daemon
  and the only loop the unit tests need;
* ``GLibLoop`` - GLib main loop through PyGObject (``GLib.io_add_watch`` for
  file descriptors, ``GLib.timeout_add`` for delays).  This is the production
  loop on the tablet, so that the ModemManager facade written with python-dbus
  (``DBusGMainLoop``) lives in the same process as the core.

``make_loop("auto")`` picks GLib when ``gi`` is importable, else selectors.

Interface used by the core (both loops implement it):

    add_reader(fd, callback)      callback(flags) with flags = READABLE|HUP|ERROR
    remove_reader(fd)
    call_later(delay_s, fn, *args) -> handle with .cancel()
    call_soon(fn, *args)
    time() -> monotonic seconds
    run() / stop()

``Op`` is a minimal single-threaded future and ``spawn()`` runs a generator
that yields ``Op`` objects (a trampoline), which keeps multi-step modem
sequences readable without asyncio.
"""

import heapq
import itertools
import logging
import select
import time as _time
from collections import deque

READABLE = 1
HUP = 2
ERROR = 4

log = logging.getLogger("shannond.loop")


class OpError(Exception):
    """Base class for failures delivered through an Op."""


class OpTimeout(OpError):
    pass


class OpCancelled(OpError):
    pass


class Op:
    """Single-threaded future: result or exception, plus done callbacks."""

    __slots__ = ("name", "_done", "_result", "_exc", "_callbacks")

    def __init__(self, name=""):
        self.name = name
        self._done = False
        self._result = None
        self._exc = None
        self._callbacks = []

    def __repr__(self):
        state = "pending"
        if self._done:
            state = "error %r" % (self._exc,) if self._exc else "done"
        return "<Op %s %s>" % (self.name, state)

    def done(self):
        return self._done

    def result(self):
        if not self._done:
            raise OpError("operation %s still pending" % self.name)
        if self._exc is not None:
            raise self._exc
        return self._result

    def exception(self):
        return self._exc if self._done else None

    def set_result(self, value=None):
        if self._done:
            return False
        self._done = True
        self._result = value
        self._fire()
        return True

    def set_exception(self, exc):
        if self._done:
            return False
        if isinstance(exc, type):
            exc = exc()
        self._done = True
        self._exc = exc
        self._fire()
        return True

    def cancel(self, reason="cancelled"):
        return self.set_exception(OpCancelled(reason))

    def add_done_callback(self, cb):
        if self._done:
            cb(self)
        else:
            self._callbacks.append(cb)

    def _fire(self):
        callbacks, self._callbacks = self._callbacks, []
        for cb in callbacks:
            try:
                cb(self)
            except Exception:  # a broken callback must not break the loop
                log.exception("Op %s callback failed", self.name)

    @classmethod
    def completed(cls, value=None, name=""):
        op = cls(name)
        op.set_result(value)
        return op

    @classmethod
    def failed(cls, exc, name=""):
        op = cls(name)
        op.set_exception(exc)
        return op


def spawn(gen, name="task"):
    """Run generator ``gen``; each ``yield op`` resumes when op completes.

    The value of the yield is the op's result; a failed op raises its
    exception inside the generator.  Returns an Op with the generator's
    return value.
    """
    task = Op(name)

    def step(send_value=None, throw=None):
        while True:
            try:
                if throw is not None:
                    exc, throw = throw, None
                    yielded = gen.throw(exc)
                else:
                    yielded = gen.send(send_value)
            except StopIteration as stop:
                task.set_result(stop.value)
                return
            except BaseException as exc:  # noqa: B902 - propagate into the task
                task.set_exception(exc)
                return
            if not isinstance(yielded, Op):
                throw = TypeError("task %s yielded %r, expected Op" % (name, yielded))
                continue
            if yielded.done():
                if yielded.exception() is not None:
                    throw = yielded.exception()
                    send_value = None
                else:
                    send_value = yielded._result
                continue
            yielded.add_done_callback(resume)
            return

    def resume(op):
        if op.exception() is not None:
            step(throw=op.exception())
        else:
            step(op._result)

    step()
    return task


class TimerHandle:
    __slots__ = ("when", "fn", "args", "cancelled", "seq")

    def __init__(self, when, seq, fn, args):
        self.when = when
        self.seq = seq
        self.fn = fn
        self.args = args
        self.cancelled = False

    def cancel(self):
        self.cancelled = True

    def __lt__(self, other):
        return (self.when, self.seq) < (other.when, other.seq)


class SelectorLoop:
    """Small poll()-based loop (stdlib only)."""

    def __init__(self, clock=_time.monotonic):
        self._clock = clock
        self._readers = {}
        self._timers = []
        self._soon = deque()
        self._seq = itertools.count()
        self._running = False
        self._poll = select.poll() if hasattr(select, "poll") else None
        if self._poll is None:  # pragma: no cover - every supported OS has poll
            import selectors
            self._selector = selectors.DefaultSelector()

    def time(self):
        return self._clock()

    def add_reader(self, fd, callback):
        if fd in self._readers:
            self._readers[fd] = callback
            return
        self._readers[fd] = callback
        if self._poll is not None:
            self._poll.register(fd, select.POLLIN | select.POLLPRI)
        else:  # pragma: no cover
            import selectors
            self._selector.register(fd, selectors.EVENT_READ)

    def remove_reader(self, fd):
        if self._readers.pop(fd, None) is None:
            return
        try:
            if self._poll is not None:
                self._poll.unregister(fd)
            else:  # pragma: no cover
                self._selector.unregister(fd)
        except (KeyError, ValueError, OSError):
            pass

    def call_later(self, delay, fn, *args):
        handle = TimerHandle(self._clock() + max(0.0, delay), next(self._seq), fn, args)
        heapq.heappush(self._timers, handle)
        return handle

    def call_soon(self, fn, *args):
        self._soon.append((fn, args))

    def call_soon_threadsafe(self, fn, *args):
        """Schedule fn from another thread and wake the loop up (self-pipe)."""
        import os
        if not hasattr(self, "_wake_pipe"):
            raise RuntimeError("call enable_threadsafe() from the loop thread first")
        self._soon.append((fn, args))
        try:
            os.write(self._wake_pipe[1], b"\0")
        except (BlockingIOError, OSError):
            pass

    def enable_threadsafe(self):
        import os
        if hasattr(self, "_wake_pipe"):
            return
        rfd, wfd = os.pipe()
        os.set_blocking(rfd, False)
        os.set_blocking(wfd, False)
        self._wake_pipe = (rfd, wfd)

        def _drain(_flags):
            try:
                while os.read(rfd, 512):
                    pass
            except BlockingIOError:
                pass
        self.add_reader(rfd, _drain)

    def close(self):
        import os
        for attr in ("_wake_pipe", "_sig_pipe"):
            pipe = getattr(self, attr, None)
            if pipe:
                for fd in pipe:
                    self.remove_reader(fd)
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                delattr(self, attr)

    def add_signal_handler(self, signum, fn):
        """Run fn() from the loop when signum arrives (self-pipe + set_wakeup_fd)."""
        import os
        import signal
        if not hasattr(self, "_sig_handlers"):
            self._sig_handlers = {}
            rfd, wfd = os.pipe()
            os.set_blocking(rfd, False)
            os.set_blocking(wfd, False)
            self._sig_pipe = (rfd, wfd)
            signal.set_wakeup_fd(wfd)

            def _drain(_flags):
                try:
                    data = os.read(rfd, 64)
                except BlockingIOError:
                    return
                for b in data:
                    cb = self._sig_handlers.get(b)
                    if cb is not None:
                        cb()
            self.add_reader(rfd, _drain)
        self._sig_handlers[signum] = fn
        signal.signal(signum, lambda *_: None)

    def stop(self):
        self._running = False

    def run(self):
        self._running = True
        while self._running:
            self.run_once()

    def run_until(self, predicate, timeout=5.0):
        """Run until predicate() is true; return its value (tests)."""
        deadline = self._clock() + timeout
        while True:
            value = predicate()
            if value:
                return value
            remaining = deadline - self._clock()
            if remaining <= 0:
                return predicate()
            self.run_once(max_wait=min(remaining, 0.05))

    def run_for(self, seconds):
        deadline = self._clock() + seconds
        while self._clock() < deadline:
            self.run_once(max_wait=min(0.05, max(0.0, deadline - self._clock())))

    def run_once(self, max_wait=None):
        timeout = None
        if self._soon:
            timeout = 0.0
        elif self._timers:
            timeout = max(0.0, self._timers[0].when - self._clock())
        if max_wait is not None:
            timeout = max_wait if timeout is None else min(timeout, max_wait)
        events = self._wait(timeout)
        for fd, flags in events:
            cb = self._readers.get(fd)
            if cb is None:
                continue
            try:
                cb(flags)
            except Exception:
                log.exception("reader callback for fd %d failed", fd)
        now = self._clock()
        while self._timers and (self._timers[0].when <= now or self._timers[0].cancelled):
            handle = heapq.heappop(self._timers)
            if handle.cancelled:
                continue
            handle.cancelled = True  # one-shot: fired handles report cancelled, cancel() is a no-op
            try:
                handle.fn(*handle.args)
            except Exception:
                log.exception("timer callback failed")
        for _ in range(len(self._soon)):
            fn, args = self._soon.popleft()
            try:
                fn(*args)
            except Exception:
                log.exception("call_soon callback failed")

    def _wait(self, timeout):
        if self._poll is not None:
            ms = None if timeout is None else int(timeout * 1000 + 0.999)
            try:
                raw = self._poll.poll(ms)
            except InterruptedError:
                return []
            out = []
            for fd, ev in raw:
                flags = 0
                if ev & (select.POLLIN | select.POLLPRI):
                    flags |= READABLE
                if ev & select.POLLHUP:
                    flags |= HUP
                if ev & (select.POLLERR | select.POLLNVAL):
                    flags |= ERROR
                out.append((fd, flags))
            return out
        # pragma: no cover - selectors fallback cannot tell HUP from IN
        if not self._readers:
            _time.sleep(timeout or 0)
            return []
        return [(key.fd, READABLE) for key, _ in self._selector.select(timeout)]


class GLibTimerHandle:
    """Timer handle for GLibLoop: same contract as TimerHandle (.when, .cancelled,
    .cancel()); cancel() also removes the GLib source."""

    __slots__ = ("_GLib", "when", "fn", "args", "cancelled", "source")

    def __init__(self, GLib, when, fn, args):
        self._GLib = GLib
        self.when = when
        self.fn = fn
        self.args = args
        self.cancelled = False
        self.source = None

    def _fire(self):
        if not self.cancelled:
            self.cancelled = True  # one-shot: a later cancel() is a no-op
            self.source = None
            try:
                self.fn(*self.args)
            except Exception:
                log.exception("timer callback failed")
        return False  # never repeat

    def cancel(self):
        if self.cancelled:
            return
        self.cancelled = True
        source, self.source = self.source, None
        if source is not None:
            try:
                self._GLib.source_remove(source)
            except Exception:
                pass


class GLibLoop:
    """The same interface on top of a GLib main loop (PyGObject).

    Use it when the ModemManager facade (python-dbus + dbus.mainloop.glib)
    lives in the same process as the core.  Imports ``gi`` lazily so the core
    never depends on it.
    """

    def __init__(self, context=None):
        from gi.repository import GLib  # noqa: deferred import (optional dependency)
        self._GLib = GLib
        self._loop = GLib.MainLoop.new(context, False)
        self._sources = {}

    def time(self):
        return self._GLib.get_monotonic_time() / 1e6

    def add_reader(self, fd, callback):
        self.remove_reader(fd)
        GLib = self._GLib
        cond = GLib.IOCondition.IN | GLib.IOCondition.PRI | GLib.IOCondition.HUP | GLib.IOCondition.ERR

        token = object()

        def _cb(_fd, condition):
            flags = 0
            if condition & (GLib.IOCondition.IN | GLib.IOCondition.PRI):
                flags |= READABLE
            if condition & GLib.IOCondition.HUP:
                flags |= HUP
            if condition & (GLib.IOCondition.ERR | GLib.IOCondition.NVAL):
                flags |= ERROR
            try:
                callback(flags)
            except Exception:
                log.exception("reader callback for fd %d failed", fd)
            entry = self._sources.get(fd)
            return entry is not None and entry[1] is token  # keep only if still registered as this watch

        source = GLib.io_add_watch(fd, GLib.PRIORITY_DEFAULT, cond, _cb)
        self._sources[fd] = (source, token)

    def remove_reader(self, fd):
        entry = self._sources.pop(fd, None)
        if entry is not None:
            try:
                self._GLib.source_remove(entry[0])
            except Exception:
                pass

    def call_later(self, delay, fn, *args):
        handle = GLibTimerHandle(self._GLib, self.time() + max(0.0, delay), fn, args)
        handle.source = self._GLib.timeout_add(max(0, int(delay * 1000)), handle._fire)
        return handle

    def call_soon(self, fn, *args):
        def _idle():
            try:
                fn(*args)
            except Exception:
                log.exception("call_soon callback failed")
            return False
        self._GLib.idle_add(_idle)

    # GLib.idle_add is thread-safe: the same call works from any thread.
    call_soon_threadsafe = call_soon

    def enable_threadsafe(self):
        pass

    def close(self):
        pass

    def add_signal_handler(self, signum, fn):
        def _cb(*_):
            fn()
            return True
        self._GLib.unix_signal_add(self._GLib.PRIORITY_HIGH, signum, _cb)

    def run(self):
        self._loop.run()

    def stop(self):
        self._loop.quit()

    def run_until(self, predicate, timeout=5.0):
        """Iterate the GLib context until predicate() is true (tests, scripts)."""
        import time as _t
        ctx = self._loop.get_context()
        deadline = _t.monotonic() + timeout
        while not predicate():
            if _t.monotonic() >= deadline:
                break
            if not ctx.iteration(False):
                _t.sleep(0.005)
        return predicate()

    def run_for(self, seconds):
        import time as _t
        end = _t.monotonic() + seconds
        self.run_until(lambda: _t.monotonic() >= end, seconds + 1)


def make_loop(kind="auto"):
    """Return a loop: ``"glib"``, ``"selectors"`` or ``"auto"`` (GLib if available)."""
    if kind in ("auto", "glib"):
        try:
            return GLibLoop()
        except ImportError:
            if kind == "glib":
                raise
    return SelectorLoop()


def wait_op(loop, op, timeout):
    """Return an Op that fails with OpTimeout if ``op`` does not finish in time."""
    out = Op(op.name)
    timer = loop.call_later(timeout, lambda: out.set_exception(OpTimeout("%s timed out" % op.name)))

    def _done(o):
        timer.cancel()
        if o.exception() is not None:
            out.set_exception(o.exception())
        else:
            out.set_result(o._result)
    op.add_done_callback(_done)
    return out


def sleep(loop, seconds):
    op = Op("sleep")
    loop.call_later(seconds, op.set_result, None)
    return op
