# SPDX-License-Identifier: GPL-2.0-or-later
"""JSON-lines control socket (/run/shannond/control), a client of ModemCore.

Request:  {"id": 1, "cmd": "status", "args": {...}}\\n
Reply:    {"id": 1, "ok": true, "result": ...}\\n  or  {"id": 1, "ok": false, "error": "..."}\\n
Events (after "subscribe"): {"event": "state", "data": {...}}\\n

The socket is created 0660 (root:radio when run as root with a "radio" group).
Identifiers (operator code/name, IMEI/IMSI/ICCID, SMS numbers and text, IP
addresses) are redacted unless the request sets "identifiers": true.
"""

import copy
import grp
import json
import logging
import os
import socket
import struct

from .loop import READABLE

log = logging.getLogger("shannond.control")

MAX_LINE = 65536
REDACT_KEYS = {"mcc", "mnc", "operator", "imei", "imsi", "iccid", "own_number", "number", "sender",
               "text", "pdu_hex", "parts_hex", "address", "dns", "gateway"}


def redact(obj):
    """Return a copy with identifier fields masked (numbers keep 2+2 digits)."""
    from .core import mask_number
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in REDACT_KEYS and v not in (None, "", []):
                if k in ("number", "sender"):
                    out[k] = mask_number(v)
                elif k == "text":
                    out[k] = "<%d chars>" % len(v)
                else:
                    out[k] = "<redacted>"
            else:
                out[k] = redact(v)
        return out
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj


class _Client:
    def __init__(self, sock, server):
        self.sock = sock
        self.server = server
        self.buf = bytearray()
        self.unsubscribe = None
        self.identifiers = False
        self.closed = False

    def send(self, obj):
        if self.closed:
            return
        data = (json.dumps(obj, separators=(",", ":"), default=str) + "\n").encode()
        try:
            self.sock.setblocking(True)
            self.sock.settimeout(2.0)
            self.sock.sendall(data)
        except OSError:
            self.close()
        finally:
            if not self.closed:
                self.sock.setblocking(False)

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.unsubscribe:
            self.unsubscribe()
        self.server.loop.remove_reader(self.sock.fileno())
        try:
            self.sock.close()
        except OSError:
            pass
        self.server.clients.discard(self)


class ControlServer:
    def __init__(self, loop, core, path="/run/shannond/control", group="radio", set_log_level=None):
        self.loop = loop
        self.core = core
        self.path = path
        self.group = group
        self.sock = None
        self.clients = set()
        self.set_log_level = set_log_level

    def start(self):
        directory = os.path.dirname(self.path)
        if directory:
            os.makedirs(directory, mode=0o750, exist_ok=True)
        try:
            if os.path.exists(self.path) or os.path.islink(self.path):
                os.unlink(self.path)
        except OSError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o117)
        try:
            self.sock.bind(self.path)
        finally:
            os.umask(old)
        os.chmod(self.path, 0o660)
        if os.geteuid() == 0 and self.group:
            try:
                gid = grp.getgrnam(self.group).gr_gid
                os.chown(self.path, 0, gid)
            except (KeyError, OSError) as exc:
                log.warning("cannot give %s to group %s: %s", self.path, self.group, exc)
        self.sock.listen(8)
        self.sock.setblocking(False)
        self.loop.add_reader(self.sock.fileno(), self._on_accept)
        log.info("control socket on %s", self.path)

    def stop(self):
        for c in list(self.clients):
            c.close()
        if self.sock is not None:
            self.loop.remove_reader(self.sock.fileno())
            self.sock.close()
            self.sock = None
            try:
                os.unlink(self.path)
            except OSError:
                pass

    def _peer_allowed(self, conn):
        """Linux: root, our own uid, or a member of the radio group (file mode does the rest)."""
        if not hasattr(socket, "SO_PEERCRED"):
            return True
        try:
            creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            _pid, uid, gid = struct.unpack("3i", creds)
        except OSError:
            return False
        if uid in (0, os.geteuid()):
            return True
        try:
            g = grp.getgrnam(self.group)
        except KeyError:
            return False
        if gid == g.gr_gid:
            return True
        try:
            import pwd
            return pwd.getpwuid(uid).pw_name in g.gr_mem
        except KeyError:
            return False

    def _on_accept(self, flags):
        try:
            conn, _ = self.sock.accept()
        except (BlockingIOError, InterruptedError):
            return
        if not self._peer_allowed(conn):
            log.warning("control: peer refused")
            conn.close()
            return
        conn.setblocking(False)
        client = _Client(conn, self)
        self.clients.add(client)
        self.loop.add_reader(conn.fileno(), lambda f, c=client: self._on_client(c, f))

    def _on_client(self, client, flags):
        try:
            data = client.sock.recv(65536)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            data = b""
        if not data:
            client.close()
            return
        client.buf += data
        if len(client.buf) > MAX_LINE and b"\n" not in client.buf:
            client.send({"ok": False, "error": "line too long"})
            client.close()
            return
        while b"\n" in client.buf:
            line, _, rest = bytes(client.buf).partition(b"\n")
            client.buf = bytearray(rest)
            if line.strip():
                self._handle_line(client, line)

    def _handle_line(self, client, line):
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError("request must be an object")
        except ValueError as exc:
            client.send({"ok": False, "error": "bad request: %s" % exc})
            return
        rid = req.get("id")
        cmd = req.get("cmd")
        args = req.get("args") or {}
        ident = bool(req.get("identifiers"))

        def reply(ok, result):
            if ok:
                client.send({"id": rid, "ok": True, "result": result if ident else redact(result)})
            else:
                client.send({"id": rid, "ok": False, "error": str(result)})

        handler = getattr(self, "cmd_" + str(cmd).replace("-", "_"), None)
        if handler is None:
            reply(False, "unknown command %r" % cmd)
            return
        try:
            handler(client, args, reply, ident)
        except (TypeError, ValueError, KeyError) as exc:
            reply(False, "bad arguments: %s" % exc)

    # ------------------------------------------------------------------ commands
    def cmd_ping(self, client, args, reply, ident):
        from . import __version__
        reply(True, {"version": __version__})

    def cmd_status(self, client, args, reply, ident):
        state = copy.deepcopy(self.core.state)
        if args.get("stats"):
            state["stats"] = self.core.stats()
        reply(True, state)

    def cmd_radio(self, client, args, reply, ident):
        on = args.get("on")
        if isinstance(on, str):
            on = on.lower() in ("1", "on", "true", "yes")
        (self.core.radio_on if on else self.core.radio_off)(reply)

    def cmd_refresh(self, client, args, reply, ident):
        self.core.refresh(reply)

    def cmd_pin_status(self, client, args, reply, ident):
        self.core.pin_status(reply)

    def cmd_pin_enter(self, client, args, reply, ident):
        self.core.enter_pin(str(args["pin"]), reply)

    def cmd_puk_enter(self, client, args, reply, ident):
        self.core.enter_puk(str(args["puk"]), str(args["pin"]), reply)

    def cmd_sms_send(self, client, args, reply, ident):
        self.core.send_sms(str(args["number"]), str(args["text"]), reply,
                           request_status_report=bool(args.get("status_report")))

    def cmd_sms_list(self, client, args, reply, ident):
        self.core.list_sms(reply)

    def cmd_sms_delete(self, client, args, reply, ident):
        self.core.delete_sms(int(args["index"]), reply)

    def cmd_call_dial(self, client, args, reply, ident):
        self.core.dial(str(args["number"]), reply)

    def cmd_call_answer(self, client, args, reply, ident):
        self.core.answer(args.get("id"), reply)

    def cmd_call_hangup(self, client, args, reply, ident):
        call_id = args.get("id")
        self.core.hangup(int(call_id) if call_id is not None else None, reply)

    def cmd_call_list(self, client, args, reply, ident):
        self.core.list_calls(reply)

    def cmd_call_dtmf(self, client, args, reply, ident):
        self.core.send_dtmf(args.get("id"), str(args["digits"]), reply)

    def cmd_audio_path(self, client, args, reply, ident):
        self.core.set_audio_path(str(args["path"]), reply)

    def cmd_mic_mute(self, client, args, reply, ident):
        self.core.set_mic_mute(bool(args.get("mute", True)), reply)

    def cmd_data_up(self, client, args, reply, ident):
        self.core.data_connect(str(args["apn"]), str(args.get("ip_type", "ipv4")), args.get("user"),
                               args.get("password"), reply, auth=args.get("auth"),
                               cid=int(args.get("cid", 1)))

    def cmd_data_down(self, client, args, reply, ident):
        self.core.data_disconnect(reply)

    def cmd_identity(self, client, args, reply, ident):
        self.core.query_identity(reply)

    def cmd_networks_scan(self, client, args, reply, ident):
        self.core.scan_networks(reply)

    def cmd_raw(self, client, args, reply, ident):
        payload = bytes.fromhex(str(args.get("hex", "")))
        self.core.raw(int(args["main"]), int(args["sub"]), int(args["type"]), payload, reply)

    def cmd_log_level(self, client, args, reply, ident):
        level = str(args["level"]).upper()
        if level not in ("DEBUG", "INFO", "WARNING", "ERROR"):
            raise ValueError("level must be debug, info, warning or error")
        target = str(args.get("logger", "shannond"))
        logging.getLogger(target).setLevel(level)
        if self.set_log_level is not None and target == "shannond":
            self.set_log_level(level)
        reply(True, {"logger": target, "level": level})

    def cmd_subscribe(self, client, args, reply, ident):
        if client.unsubscribe is None:
            client.identifiers = ident

            def forward(event, data):
                client.send({"event": event, "data": data if client.identifiers else redact(data)})
            client.unsubscribe = self.core.subscribe(forward)
        reply(True, {"subscribed": True})
        client.send({"event": "state", "data": copy.deepcopy(self.core.state) if ident
                     else redact(self.core.state)})
