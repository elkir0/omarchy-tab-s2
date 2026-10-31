# SPDX-License-Identifier: GPL-2.0-or-later
"""Event-loop contract tests, run on SelectorLoop and (when gi is importable) on GLibLoop."""

import os
import socket
import unittest

import testutil  # noqa: F401
from shannond import loop as L

try:
    import gi  # noqa: F401
    from gi.repository import GLib  # noqa: F401
    HAVE_GI = True
except (ImportError, ValueError):
    HAVE_GI = False


class LoopContract:
    """Mixin: every backend must satisfy these (handle contract included)."""

    def make_loop(self):
        raise NotImplementedError

    def setUp(self):
        self.loop = self.make_loop()

    def test_call_later_fires_once(self):
        hits = []
        h = self.loop.call_later(0.01, hits.append, 1)
        self.assertTrue(self.loop.run_until(lambda: hits, 2.0))
        self.loop.run_for(0.05)
        self.assertEqual(hits, [1])
        self.assertTrue(h.cancelled, "a fired one-shot handle reports cancelled=True")
        h.cancel()  # cancel after firing: no-op, no exception
        self.assertIsInstance(h.when, float)

    def test_cancel_prevents_firing(self):
        hits = []
        h = self.loop.call_later(0.02, hits.append, 1)
        h.cancel()
        h.cancel()  # idempotent
        self.assertTrue(h.cancelled)
        self.loop.run_for(0.1)
        self.assertEqual(hits, [])

    def test_timer_order(self):
        hits = []
        self.loop.call_later(0.03, hits.append, "b")
        self.loop.call_later(0.01, hits.append, "a")
        self.loop.run_until(lambda: len(hits) == 2, 2.0)
        self.assertEqual(hits, ["a", "b"])

    def test_call_soon(self):
        hits = []
        self.loop.call_soon(hits.append, 3)
        self.assertTrue(self.loop.run_until(lambda: hits, 1.0))

    def test_reader_readable_and_remove(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        seen = []

        def on_ready(flags):
            seen.append(flags)
            os.read(a.fileno(), 100)
        self.loop.add_reader(a.fileno(), on_ready)
        b.send(b"x")
        self.assertTrue(self.loop.run_until(lambda: seen, 2.0))
        self.assertTrue(seen[0] & L.READABLE)
        self.loop.remove_reader(a.fileno())
        self.loop.remove_reader(a.fileno())  # idempotent
        b.send(b"y")
        self.loop.run_for(0.05)
        self.assertEqual(len(seen), 1)

    def test_reader_reregistered_from_its_callback(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        seen = []

        def on_ready(flags):
            seen.append(flags)
            os.read(a.fileno(), 100)
            self.loop.remove_reader(a.fileno())
            self.loop.add_reader(a.fileno(), on_ready)
        self.loop.add_reader(a.fileno(), on_ready)
        b.send(b"1")
        self.loop.run_until(lambda: len(seen) >= 1, 2.0)
        b.send(b"2")
        self.loop.run_until(lambda: len(seen) >= 2, 2.0)
        self.assertEqual(len(seen), 2)

    def test_peer_close_is_reported(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        seen = []

        def on_ready(flags):
            seen.append(flags)
            data = os.read(a.fileno(), 100) if flags & L.READABLE else b""
            if not data:
                self.loop.remove_reader(a.fileno())
        self.loop.add_reader(a.fileno(), on_ready)
        b.close()
        self.assertTrue(self.loop.run_until(lambda: seen, 2.0))

    def test_spawn_and_wait_op(self):
        def gen():
            v = yield L.sleep(self.loop, 0.01)
            self.assertIsNone(v)
            try:
                yield L.wait_op(self.loop, L.Op("never"), 0.02)
            except L.OpTimeout:
                return "timed out"
            return "no"
        task = L.spawn(gen())
        self.assertTrue(self.loop.run_until(task.done, 2.0))
        self.assertEqual(task.result(), "timed out")


class SelectorLoopTest(LoopContract, unittest.TestCase):
    def make_loop(self):
        return L.SelectorLoop()


@unittest.skipUnless(HAVE_GI, "PyGObject (gi) not installed: GLib backend not testable here")
class GLibLoopTest(LoopContract, unittest.TestCase):
    def make_loop(self):
        return L.GLibLoop()

    def test_handle_class(self):
        h = self.loop.call_later(10, lambda: None)
        self.assertIsInstance(h, L.GLibTimerHandle)
        self.assertIsNotNone(h.source)
        h.cancel()
        self.assertIsNone(h.source)


class OpTest(unittest.TestCase):
    def test_op_callbacks_and_errors(self):
        op = L.Op("x")
        got = []
        op.add_done_callback(lambda o: got.append(o.result()))
        op.set_result(5)
        op.set_result(6)  # ignored
        self.assertEqual(got, [5])
        bad = L.Op.failed(ValueError("boom"))
        self.assertRaises(ValueError, bad.result)
        self.assertIsInstance(bad.exception(), ValueError)

    def test_spawn_propagates_exceptions(self):
        def gen():
            yield L.Op.failed(KeyError("k"))
        task = L.spawn(gen())
        self.assertTrue(task.done())
        self.assertIsInstance(task.exception(), KeyError)

    def test_spawn_rejects_non_op(self):
        def gen():
            yield 42
        task = L.spawn(gen())
        self.assertIsInstance(task.exception(), TypeError)

    def test_make_loop(self):
        self.assertIsInstance(L.make_loop("selectors"), L.SelectorLoop)
        loop = L.make_loop("auto")
        self.assertIsInstance(loop, L.GLibLoop if HAVE_GI else L.SelectorLoop)


if __name__ == "__main__":
    unittest.main()
