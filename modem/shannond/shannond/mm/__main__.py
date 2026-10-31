# SPDX-License-Identifier: GPL-2.0-or-later
"""Standalone facade on the fake core: ``python3 -m shannond.mm --fake``.

Used by the integration test and for desktop demos without the modem.
Signals: SIGUSR1 injects a received SMS, SIGUSR2 an incoming call,
SIGHUP simulates a CP crash followed by a recovery two seconds later.
"""

import argparse
import logging
import signal
import sys


def main(argv=None):
    parser = argparse.ArgumentParser(prog="python3 -m shannond.mm",
                                     description="shannon2mm ModemManager facade on the fake core")
    parser.add_argument("--fake", action="store_true", required=True,
                        help="use the fake core (the real core is attached by shannond --mm)")
    parser.add_argument("--bus", choices=("system", "session"), default="system")
    parser.add_argument("--locked", action="store_true", help="SIM starts PIN-locked (PIN 1234)")
    parser.add_argument("--no-sim", action="store_true", help="no SIM inserted")
    parser.add_argument("--power", choices=("off", "lpm", "on"), default="lpm")
    parser.add_argument("--delay", type=float, default=0.1, help="fake modem latency in seconds")
    parser.add_argument("--identity", choices=("eager", "on-demand", "never"), default="eager")
    parser.add_argument("--net-port", action="append", dest="net_ports",
                        help="rmnet interface to list as a net port (repeatable)")
    parser.add_argument("--stored-sms", type=int, default=1, help="SMS already in the fake SIM storage")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")

    from gi.repository import GLib

    from ..loop import GLibLoop
    from . import attach
    from .fake import FakeCore

    loop = GLibLoop()
    core = FakeCore(loop, delay=args.delay, sim_locked=args.locked, sim_present=not args.no_sim,
                    power=args.power)
    for _ in range(args.stored_sms):
        core.store_sms()
    options = {"identity": args.identity}
    if args.net_ports:
        options["net_ports"] = args.net_ports
    from .service import NameTakenError
    try:
        handle = attach(core, loop, bus=args.bus, **options)
    except NameTakenError as exc:
        print("shannon2mm: %s" % exc, file=sys.stderr)
        return 2

    def on_usr1():
        core.inject_sms()
        return True

    def on_usr2():
        core.incoming_call()
        return True

    def on_hup():
        core.crash()
        loop.call_later(2.0, core.recover)
        return True

    def on_term():
        loop.stop()
        return False

    try:
        from gi.repository import GLibUnix
        signal_add = GLibUnix.signal_add
    except ImportError:  # PyGObject < 3.52
        signal_add = GLib.unix_signal_add
    for signum, fn in ((signal.SIGUSR1, on_usr1), (signal.SIGUSR2, on_usr2), (signal.SIGHUP, on_hup),
                       (signal.SIGTERM, on_term), (signal.SIGINT, on_term)):
        signal_add(GLib.PRIORITY_DEFAULT, signum, fn)

    print("shannon2mm fake facade ready on the %s bus" % args.bus, flush=True)
    try:
        loop.run()
    finally:
        handle.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
