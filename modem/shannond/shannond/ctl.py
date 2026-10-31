# SPDX-License-Identifier: GPL-2.0-or-later
"""shannonctl: command-line client of the shannond control socket.

    shannonctl status [--stats] [--identifiers]
    shannonctl radio on|off
    shannonctl pin-status
    shannonctl pin-enter                      (PIN read from the terminal, never from argv)
    shannonctl sms send NUMBER TEXT
    shannonctl sms list [--show]
    shannonctl sms delete INDEX
    shannonctl call dial NUMBER | answer [ID] | hangup [ID] | list | dtmf ID DIGITS
    shannonctl data up APN [--ip-type ipv4|ipv6|ipv4v6] [--user U] [--password-stdin] | down
    shannonctl identity [--show]
    shannonctl raw MAIN SUB TYPE [HEX]        (debug; numbers accept 0x..)
    shannonctl log-level debug|info|warning|error [--logger NAME]
    shannonctl monitor [--identifiers]        (stream events)

Output is JSON.  Numbers and SMS text are masked unless --show/--identifiers.
"""

import argparse
import getpass
import json
import os
import socket
import sys

DEFAULT_SOCKET = os.environ.get("SHANNOND_SOCKET", "/run/shannond/control")


class CtlError(Exception):
    pass


class Connection:
    def __init__(self, path, timeout=120.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(path)
        except OSError as exc:
            raise CtlError("cannot connect to %s: %s" % (path, exc.strerror or exc))
        self.buf = b""
        self.next_id = 1

    def request(self, cmd, args=None, identifiers=False):
        rid = self.next_id
        self.next_id += 1
        msg = {"id": rid, "cmd": cmd, "args": args or {}}
        if identifiers:
            msg["identifiers"] = True
        self.sock.sendall((json.dumps(msg) + "\n").encode())
        while True:
            obj = self.read()
            if obj.get("id") == rid:
                return obj

    def read(self):
        while b"\n" not in self.buf:
            data = self.sock.recv(65536)
            if not data:
                raise CtlError("connection closed by shannond")
            self.buf += data
        line, _, self.buf = self.buf.partition(b"\n")
        return json.loads(line)

    def close(self):
        self.sock.close()


def _int(text):
    return int(text, 0)


def build_parser():
    p = argparse.ArgumentParser(prog="shannonctl", description="control shannond")
    p.add_argument("--socket", default=DEFAULT_SOCKET, help="control socket (default %(default)s)")
    p.add_argument("--timeout", type=float, default=120.0)
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("status")
    s.add_argument("--stats", action="store_true")
    s.add_argument("--identifiers", action="store_true", help="show operator code/name and identifiers")
    sub.add_parser("ping")
    s = sub.add_parser("radio")
    s.add_argument("state", choices=("on", "off"))
    sub.add_parser("refresh")
    sub.add_parser("pin-status")
    sub.add_parser("pin-enter")
    s = sub.add_parser("puk-enter")
    del s

    sms = sub.add_parser("sms").add_subparsers(dest="sms_cmd", required=True)
    s = sms.add_parser("send")
    s.add_argument("number")
    s.add_argument("text")
    s.add_argument("--status-report", action="store_true")
    s = sms.add_parser("list")
    s.add_argument("--show", action="store_true", help="show numbers and texts")
    s = sms.add_parser("delete")
    s.add_argument("index", type=int)

    call = sub.add_parser("call").add_subparsers(dest="call_cmd", required=True)
    s = call.add_parser("dial")
    s.add_argument("number")
    s = call.add_parser("answer")
    s.add_argument("id", nargs="?", type=int)
    s = call.add_parser("hangup")
    s.add_argument("id", nargs="?", type=int)
    s = call.add_parser("list")
    s.add_argument("--show", action="store_true")
    s = call.add_parser("dtmf")
    s.add_argument("id", type=int)
    s.add_argument("digits")

    data = sub.add_parser("data").add_subparsers(dest="data_cmd", required=True)
    s = data.add_parser("up")
    s.add_argument("apn")
    s.add_argument("--ip-type", default="ipv4", choices=("ipv4", "ipv6", "ipv4v6"))
    s.add_argument("--user")
    s.add_argument("--password-stdin", action="store_true", help="read the APN password from stdin")
    s.add_argument("--auth", choices=("none", "pap", "chap"))
    s.add_argument("--cid", type=int, default=1)
    s.add_argument("--show", action="store_true", help="show addresses")
    data.add_parser("down")

    s = sub.add_parser("identity")
    s.add_argument("--show", action="store_true", help="print IMEI/IMSI/ICCID in clear")
    sub.add_parser("networks")
    s = sub.add_parser("audio-path")
    s.add_argument("path", choices=("speaker", "headphone", "handset", "headset"))
    s = sub.add_parser("mic-mute")
    s.add_argument("state", choices=("on", "off"))

    s = sub.add_parser("raw")
    s.add_argument("main", type=_int)
    s.add_argument("sub", type=_int)
    s.add_argument("type", type=_int)
    s.add_argument("hex", nargs="?", default="")
    s = sub.add_parser("log-level")
    s.add_argument("level", choices=("debug", "info", "warning", "error"))
    s.add_argument("--logger", default="shannond")
    s = sub.add_parser("monitor")
    s.add_argument("--identifiers", action="store_true")
    return p


def _request_for(args):
    """Map parsed arguments to (cmd, args, identifiers)."""
    c = args.command
    if c == "status":
        return "status", {"stats": args.stats}, args.identifiers
    if c in ("ping", "refresh", "pin-status"):
        return c, {}, False
    if c == "radio":
        return "radio", {"on": args.state == "on"}, False
    if c == "pin-enter":
        pin = getpass.getpass("SIM PIN: ")
        return "pin-enter", {"pin": pin}, False
    if c == "puk-enter":
        puk = getpass.getpass("SIM PUK: ")
        pin = getpass.getpass("new PIN: ")
        return "puk-enter", {"puk": puk, "pin": pin}, False
    if c == "sms":
        if args.sms_cmd == "send":
            return "sms-send", {"number": args.number, "text": args.text,
                                "status_report": args.status_report}, False
        if args.sms_cmd == "list":
            return "sms-list", {}, args.show
        return "sms-delete", {"index": args.index}, False
    if c == "call":
        if args.call_cmd == "dial":
            return "call-dial", {"number": args.number}, False
        if args.call_cmd == "answer":
            return "call-answer", {"id": args.id}, False
        if args.call_cmd == "hangup":
            return "call-hangup", {"id": args.id}, False
        if args.call_cmd == "list":
            return "call-list", {}, args.show
        return "call-dtmf", {"id": args.id, "digits": args.digits}, False
    if c == "data":
        if args.data_cmd == "up":
            req = {"apn": args.apn, "ip_type": args.ip_type, "cid": args.cid}
            if args.user:
                req["user"] = args.user
            if args.password_stdin:
                req["password"] = sys.stdin.readline().rstrip("\n")
            if args.auth:
                req["auth"] = args.auth
            return "data-up", req, args.show
        return "data-down", {}, False
    if c == "identity":
        return "identity", {}, args.show
    if c == "networks":
        return "networks-scan", {}, False
    if c == "audio-path":
        return "audio-path", {"path": args.path}, False
    if c == "mic-mute":
        return "mic-mute", {"mute": args.state == "on"}, False
    if c == "raw":
        return "raw", {"main": args.main, "sub": args.sub, "type": args.type, "hex": args.hex}, False
    if c == "log-level":
        return "log-level", {"level": args.level, "logger": args.logger}, False
    raise CtlError("unknown command %s" % c)


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        conn = Connection(args.socket, args.timeout)
        if args.command == "monitor":
            reply = conn.request("subscribe", {}, args.identifiers)
            if not reply.get("ok"):
                raise CtlError(reply.get("error", "subscribe failed"))
            try:
                while True:
                    print(json.dumps(conn.read(), ensure_ascii=False), flush=True)
            except KeyboardInterrupt:
                return 0
        cmd, req, ident = _request_for(args)
        reply = conn.request(cmd, req, ident)
        conn.close()
    except (CtlError, OSError, ValueError) as exc:
        print("shannonctl: %s" % exc, file=sys.stderr)
        return 2
    if reply.get("ok"):
        print(json.dumps(reply.get("result"), indent=2, ensure_ascii=False, sort_keys=True))
        return 0
    print("shannonctl: %s" % reply.get("error"), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
