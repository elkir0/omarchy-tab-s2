# SPDX-License-Identifier: GPL-2.0-or-later
"""shannond entry point: ``python3 -m shannond [options]``."""

import argparse
import logging
import os
import signal
import sys

from . import __version__, defs
from .core import CoreConfig, ModemCore
from .loop import make_loop
from .netcfg import NetConfig
from .settings import Settings

log = logging.getLogger("shannond")


def build_parser():
    p = argparse.ArgumentParser(prog="shannond", description="Shannon SS333 modem daemon (Samsung IPC 4.1 + RFS)")
    p.add_argument("--ipc", default="/dev/umts_ipc0", help="FMT device (default %(default)s)")
    p.add_argument("--rfs", default="/dev/umts_rfs0", help="RFS device (default %(default)s)")
    p.add_argument("--no-rfs", action="store_true", help="do not open or serve the RFS device")
    p.add_argument("--passive", action="store_true",
                   help="answer only the mandatory messages (SMS_DEVICE_READY, IPC_LOOPBACK, RFS); send nothing else")
    p.add_argument("--log-payload", metavar="DIR",
                   help="also write payload hex dumps under DIR (identifiers inside: keep it private)")
    p.add_argument("--control", default="/run/shannond/control", help="control socket path (default %(default)s)")
    p.add_argument("--control-group", default="radio", help="group owning the control socket")
    p.add_argument("--no-control", action="store_true", help="no control socket")
    p.add_argument("--loop", choices=("auto", "glib", "selectors"), default="auto",
                   help="event loop (auto = GLib if PyGObject is installed)")
    p.add_argument("--mm", action="store_true",
                   help="attach the ModemManager D-Bus facade (shannond.mm) in this process (needs gi + dbus)")
    p.add_argument("--log-level", default="info", choices=("debug", "info", "warning", "error"))
    p.add_argument("--nv-seed", default="/var/lib/shannon/nv/nv_data.bin",
                   help="verified NV snapshot, opened read-only ('none' to disable NV verbs)")
    p.add_argument("--efs-lower", default="/var/lib/shannon/efs-root",
                   help="read-only lower layer for RFS file verbs (copy of efs/root)")
    p.add_argument("--rfs-upper", default="/run/shannond/rfs", help="tmpfs upper layer for RFS file verbs")
    p.add_argument("--configure-ip", action="store_true",
                   help="configure rmnet with iproute2 (default: publish the configuration only)")
    p.add_argument("--route-metric", type=int, default=700,
                   help="metric of the rmnet default route with --configure-ip (default %(default)s, above Wi-Fi)")
    p.add_argument("--no-default-route", action="store_true", help="with --configure-ip, add no default route")
    p.add_argument("--configure-dns", action="store_true", help="with --configure-ip, push DNS to systemd-resolved")
    p.add_argument("--data-state-dir", default="/run/shannond/data", help="where data configuration is published")
    p.add_argument("--audio-hook", metavar="CMD",
                   help="command run as 'CMD open|close RATE PATH' when call audio must open/close")
    p.add_argument("--audio-path", default="speaker", choices=("speaker", "headphone", "handset", "headset"))
    p.add_argument("--no-mode-sel", action="store_true", help="do not send NET_MODE_SEL on radio on")
    p.add_argument("--modes", default="lte,umts,gsm",
                   help="radio access technologies sent in NET_MODE_SEL on radio on (lte, umts, gsm)")
    p.add_argument("--settings", metavar="FILE",
                   help="keep the user's attach APN and technologies here; they win over --lte-apn and --modes")
    p.add_argument("--lte-apn", metavar="APN",
                   help="LTE attach APN, sent before every radio on (needed on networks that reject the "
                        "CP's own attach profile; keep it in a local file, not in the repository)")
    p.add_argument("--radio-on", action="store_true",
                   help="turn the radio on as soon as the CP is ready, also after a CP restart "
                        "(without it the radio waits for a client, and calls and SMS do not arrive)")
    p.add_argument("--no-lte-attach", action="store_true",
                   help="do not send GPRS_LTE_ATTACH_APN_INFO before a data call (keep the CP's NV attach profile)")
    p.add_argument("--cp-state", default="/run/shannon/cp-state",
                   help="loader session file 'session=N state=...' (restart contract; '' to disable)")
    p.add_argument("--restore-radio", action="store_true",
                   help="after a CP restart, send radio on again if it was on (default: GETs only)")
    p.add_argument("--rfs-inline", action="store_true",
                   help="serve RFS on the main loop instead of its own thread (debugging)")
    p.add_argument("--smsc", choices=("cp", "empty"), default="cp",
                   help="SMSC for outgoing SMS: ask the CP (default) or send an empty SMSC")
    p.add_argument("--version", action="version", version="shannond " + __version__)
    return p


def setup_logging(level):
    logging.basicConfig(level=getattr(logging, level.upper()), stream=sys.stderr,
                        format="%(levelname)s %(name)s: %(message)s")


def modes_mask(text):
    bits = {"lte": defs.NET_MODE_LTE, "umts": defs.NET_MODE_WCDMA, "gsm": defs.NET_MODE_GSM}
    mask = 0
    for name in filter(None, (t.strip().lower() for t in text.split(","))):
        if name not in bits:
            raise SystemExit("--modes: unknown technology %r (lte, umts, gsm)" % name)
        mask |= bits[name]
    if not mask:
        raise SystemExit("--modes: empty")
    return mask


def main(argv=None):
    args = build_parser().parse_args(argv)
    setup_logging(args.log_level)
    loop = make_loop("glib" if args.mm and args.loop == "auto" else args.loop)
    log.info("shannond %s starting (%s loop)", __version__, type(loop).__name__)

    rfs_server = None
    if not args.no_rfs:
        from .rfs import RfsServer
        rfs_server = RfsServer(None if args.nv_seed == "none" else args.nv_seed, args.rfs_upper,
                               args.efs_lower or None)
    netcfg = NetConfig("iproute2" if args.configure_ip else "external", state_dir=args.data_state_dir,
                       route_metric=args.route_metric, default_route=not args.no_default_route,
                       configure_dns=args.configure_dns)
    config = CoreConfig(mode_sel_on_radio=not args.no_mode_sel, smsc_mode=args.smsc, audio_path=args.audio_path,
                        restore_radio=args.restore_radio, lte_attach=not args.no_lte_attach,
                        lte_attach_apn=args.lte_apn, radio_on_start=args.radio_on,
                        mode_sel_mask=modes_mask(args.modes),
                        settings=Settings(args.settings) if args.settings else None)
    core = ModemCore(loop, args.ipc, None if args.no_rfs else args.rfs, passive=args.passive,
                     rfs_server=rfs_server, netcfg=netcfg, payload_log_dir=args.log_payload,
                     audio_hook_cmd=args.audio_hook, config=config, cp_state_path=args.cp_state or None,
                     rfs_threaded=not args.rfs_inline)
    try:
        core.start()
    except OSError as exc:
        log.error("cannot open the modem devices: %s", exc)
        return 1

    control = None
    if not args.no_control:
        from .control import ControlServer
        control = ControlServer(loop, core, args.control, group=args.control_group,
                                set_log_level=lambda lvl: logging.getLogger().setLevel(lvl))
        try:
            control.start()
        except OSError as exc:
            log.error("cannot create the control socket %s: %s", args.control, exc)
            core.stop()
            return 1

    if args.mm:
        try:
            from .mm import attach
        except ImportError as exc:
            log.error("--mm needs PyGObject (gi) and python-dbus: %s", exc)
            if control is not None:
                control.stop()
            core.stop()
            return 1
        try:
            attach(core, loop)
        except ImportError as exc:
            log.error("--mm needs PyGObject (gi) and python-dbus: %s", exc)
            if control is not None:
                control.stop()
            core.stop()
            return 1
        except Exception as exc:  # NameTakenError (RuntimeError), DBusException (no bus), ...
            log.error("ModemManager facade not started (%s: %s); the core and the control socket keep running",
                      type(exc).__name__, exc)

    def _quit(*_):
        log.info("stopping")
        loop.stop()

    loop.add_signal_handler(signal.SIGTERM, _quit)
    loop.add_signal_handler(signal.SIGINT, _quit)
    try:
        loop.run()
    finally:
        if control is not None:
            control.stop()
        core.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
