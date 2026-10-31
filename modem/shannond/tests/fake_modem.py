#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Fake Shannon CP for shannond tests (MOCK: not the real modem's behaviour).

It plays the start-up traffic of the IPC 4.1 catalogue §10 (PWR_UP N,
PHONE_STATE N, SEC_PIN_STATUS N, SEC_SIM_ICC_TYPE N, SMS_DEVICE_READY N, plus
MISC_IPC_LOOPBACK and two unknown frames) and answers the requests shannond
sends with plausible, catalogue-sized frames.  All identifiers are fictional:
test PLMN 00101, numbers in the ranges reserved for fiction, TEST-NET IPs.

In-process use (tests): ``FakeModem(loop, ipc_fd, rfs_fd)`` on a socketpair.
Standalone: ``python3 tests/fake_modem.py --dir DIR`` creates two raw ptys and
the symlinks DIR/ipc and DIR/rfs, for ``shannond --ipc DIR/ipc --rfs DIR/rfs``.
"""

import errno
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

from shannond import defs  # noqa: E402
from shannond.ipc import Frame, FrameSplitter  # noqa: E402
from shannond.loop import READABLE  # noqa: E402

FAKE_SMSC_FIELD = bytes.fromhex("07913336990890F9")      # +33639980099 (fiction range)
FAKE_PEER = "+447700900456"                               # Ofcom drama range
FAKE_PEER_FIELD = bytes.fromhex("0C91447700094065")
FAKE_PLMN = b"00101#"                                     # ITU test network
FAKE_IMEI = b"000000000000000"
FAKE_OWN_NUMBER = "+15550101"
FAKE_SPN = "TestNet"
FAKE_IMSI = b"001010000000001"
# SMS-DELIVER "hellohello" from FAKE_PEER via FAKE_SMSC, 2026-10-29 21:30:15 +01:00
FAKE_DELIVER_PDU = bytes.fromhex("07913336990890F9" "04" "0C91447700094065" "00" "00"
                                 "62019212035140" "0A" "E8329BFD4697D9EC37")


class SbdWriter:
    """Emulates the kernel's uplink write semantics for the AP side (SYNTHESIS v2 §2.9, C54).

    Each write() is truncated to the 2048-byte SBD slot and returns the short
    count; every ``busy_every``-th call fails with EBUSY (1024 skbs queued).
    Pass it as ``writer=`` to ModemCore / the channels.
    """

    def __init__(self, slot=2048, busy_every=0):
        self.slot = slot
        self.busy_every = busy_every
        self.calls = 0
        self.busy = 0
        self.short = 0
        self.max_chunk = 0

    def __call__(self, fd, data):
        self.calls += 1
        if self.busy_every and self.calls % self.busy_every == 0:
            self.busy += 1
            raise OSError(errno.EBUSY, "SBD queue full (emulated)")
        chunk = bytes(data[:self.slot])
        if len(chunk) < len(data):
            self.short += 1
        n = os.write(fd, chunk)
        self.max_chunk = max(self.max_chunk, n)
        return n


def regist_payload(domain, status=0x02, act=0x21):
    """19-byte NET_REGIST (IPC 4.1 layout)."""
    return (struct.pack("<BBBBHIB", act, domain, status, 0, 0x1234, 0x00ABCDEF, 0)
            + struct.pack("<HBBBHB", 0x5678, 1, 0, 0, 0x0042, 0))


def serving_payload(status=0x02, act=0x21):
    """26-byte NET_SERVING_NETWORK."""
    return bytes([0, status, act]) + FAKE_PLMN + struct.pack("<H", 0x1234) + bytes(15)


def rssi_payload(rssi=75, rsrp=95):
    """9-byte DISP_RSSI_INFO."""
    return bytes([rssi, 3, 0, 0, rsrp, 10]) + struct.pack("<h", 200 + 12) + bytes([0xFF])


def icon_payload(bars=3, rsrp=95):
    """10-byte DISP_ICON_INFO."""
    return bytes([0x01, bars, 0, 0, 0, rsrp, 10]) + struct.pack("<h", 212) + bytes([0xFF])


def ip_config_payload(cid, mtu=1430):
    """157-byte GPRS_IP_CONFIGURATION (TEST-NET-1 addresses)."""
    p = bytearray(157)
    p[0] = cid
    struct.pack_into("<H", p, 1, 0x0001 | 0x2000)
    p[3:7] = bytes([192, 0, 2, 10])
    p[7:11] = bytes([192, 0, 2, 53])
    p[11:15] = bytes([192, 0, 2, 54])
    struct.pack_into("<I", p, 152, mtu)
    return bytes(p)


class FakeModem:
    def __init__(self, loop, ipc_fd, rfs_fd=None, stream=False, pin_status=(0x00, 0x00),
                 send_clock=True, delay=0.01):
        self.loop = loop
        self.ipc_fd = ipc_fd
        self.rfs_fd = rfs_fd
        self.splitter = FrameSplitter(stream=stream)
        self.rx = []            # frames from the AP
        self.rfs_rx = b""       # raw bytes from the AP on the RFS channel
        self.mseq = 0
        self.pin_status = pin_status
        self.send_clock = send_clock
        self.delay = delay
        self.calls = {}         # id -> dict(state, direction)
        self.next_call_id = 1
        self.sms_ref = 0x10
        self.pdp_up = set()
        self.pdp_mtu = 1430
        self.pdp_refuse = []    # causes of the next activations to refuse (status 3)
        self.fail_next = {}     # (main, sub) -> GEN code to return once
        self.sbd = SbdWriter()  # use as ModemCore(writer=fake.sbd) to emulate kernel truncation
        loop.add_reader(ipc_fd, self._on_ipc)
        if rfs_fd is not None:
            loop.add_reader(rfs_fd, self._on_rfs)

    # ---------------------------------------------------------------- output
    def _write(self, frame):
        os.write(self.ipc_fd, frame.encode())

    def send(self, main, sub, typ=defs.TYPE_NOTI, payload=b"", aseq=0):
        self.mseq = self.mseq % 255 + 1
        self._write(Frame(self.mseq, aseq, main, sub, typ, bytes(payload)))

    def later(self, fn, *args, steps=1):
        self.loop.call_later(self.delay * steps, fn, *args)

    def resp(self, req, payload):
        self.send(req.main, req.sub, defs.TYPE_RESP, payload, aseq=req.mseq)

    def gen(self, req, code=defs.GEN_OK):
        self.send(defs.GEN, defs.GEN_PHONE_RES_SUB, defs.TYPE_RESP,
                  struct.pack("<BBBH", req.main, req.sub, req.type, code), aseq=req.mseq)

    def boot(self):
        """Start-up traffic of catalogue §10, plus frames shannond must ignore."""
        self.send(defs.PWR, defs.PWR_PHONE_PWR_UP)
        self.send(defs.PWR, defs.PWR_PHONE_STATE, payload=b"\x01")
        self.send(defs.SEC, defs.SEC_PIN_STATUS, payload=bytes(self.pin_status))
        self.send(defs.SEC, defs.SEC_SIM_ICC_TYPE, payload=b"\x02")
        self.send(defs.SMS, defs.SMS_DEVICE_READY)
        self.send(defs.MISC, defs.MISC_IPC_LOOPBACK, defs.TYPE_INDI, struct.pack("<H", 0xBEEF))
        self.send(defs.MISC, 0x99, payload=b"\x01\x02\x03")        # unknown sub
        self.send(0x42, 0x01, payload=b"\x00" * 4)                  # unknown group
        self.send(defs.GPRS, defs.GPRS_LTE_CA_STATUS, payload=b"\x00\x00")  # known name, no handler

    # ---------------------------------------------------------------- scenario helpers
    def inject_sms(self, pdu=FAKE_DELIVER_PDU, msg_id=7, index=0xFFFF):
        payload = struct.pack("<BBHBB", 0x02, 0x01, index, msg_id, len(pdu)) + pdu
        self.send(defs.SMS, defs.SMS_INCOMING_MSG, payload=payload)

    def incoming_call(self, number=FAKE_PEER):
        cid = self.next_call_id
        self.next_call_id += 1
        self.calls[cid] = {"state": 5, "direction": "in", "number": number}
        self.send(defs.CALL, defs.CALL_INCOMING, payload=bytes([0x00, 0x01, cid, 0x01]))
        return cid

    def remote_hangup(self, cid):
        self.calls.pop(cid, None)
        self._call_status(cid, 4, cause=16)

    def _call_status(self, cid, status, cause=0):
        self.send(defs.CALL, defs.CALL_STATUS, payload=bytes([0x00, 0x01, cid, status, 0, cause]))

    def frames(self, main=None, sub=None, typ=None):
        return [f for f in self.rx if (main is None or f.main == main) and (sub is None or f.sub == sub)
                and (typ is None or f.type == typ)]

    # ---------------------------------------------------------------- input
    def _on_rfs(self, flags):
        try:
            data = os.read(self.rfs_fd, 0x90000)
        except BlockingIOError:
            return
        if not data:
            self.loop.remove_reader(self.rfs_fd)
            return
        self.rfs_rx += data

    def send_rfs(self, data):
        os.write(self.rfs_fd, data)

    def _on_ipc(self, flags):
        if not flags & READABLE:
            self.loop.remove_reader(self.ipc_fd)
            return
        try:
            data = os.read(self.ipc_fd, 65536)
        except BlockingIOError:
            return
        if not data:
            self.loop.remove_reader(self.ipc_fd)
            return
        for frame in self.splitter.feed(data):
            self.rx.append(frame)
            self._handle(frame)

    def _handle(self, f):
        key = (f.main, f.sub)
        if key in self.fail_next:
            self.gen(f, self.fail_next.pop(key))
            return
        if f.type in (defs.TYPE_CFRM, defs.TYPE_EVENT):
            return
        h = getattr(self, "_h_%02x_%02x" % key, None)
        if h is None:
            if f.type == defs.TYPE_GET:
                self.gen(f, 0x8002)  # unsupported GET answered by GEN (catalogue §0)
            else:
                self.gen(f)
            return
        h(f)

    # SEC_RSIM_ACCESS: EF_MSISDN and EF_SPN, as the SS333 answers with the USIM AID
    def _h_05_05(self, f):
        cmd, app = f.payload[0], f.payload[1]
        fid = struct.unpack_from("<H", f.payload, 19)[0]
        data = None
        if app == defs.RSIM_APP_USIM and fid == defs.EF_MSISDN and cmd == defs.RSIM_GET_RESPONSE:
            data = bytes.fromhex("621a82054221001c01") + bytes(19)
        elif app == defs.RSIM_APP_USIM and fid == defs.EF_MSISDN and cmd == defs.RSIM_READ_RECORD:
            bcd = bytes.fromhex("51551010")  # 15550101 in swapped semi-octets
            data = b"\xff" * 14 + bytes([1 + len(bcd), 0x91]) + bcd + b"\xff" * (12 - len(bcd))
        elif app == defs.RSIM_APP_USIM and fid == defs.EF_SPN and cmd == defs.RSIM_READ_BINARY:
            data = b"\x01" + FAKE_SPN.encode() + b"\xff" * (16 - len(FAKE_SPN))
        if data is None:
            self.resp(f, bytes([0x6A, 0x82, 0]))
        else:
            self.resp(f, bytes([0x90, 0x00, len(data)]) + data)

    # PWR_PHONE_STATE
    def _h_01_07(self, f):
        self.gen(f)
        state = struct.unpack("<H", f.payload[:2])[0]
        if state == defs.PWR_STATE_NORMAL:
            self.later(self.send, defs.PWR, defs.PWR_PHONE_STATE, defs.TYPE_NOTI, b"\x02")
            self.later(self.send, defs.NET, defs.NET_REGIST, defs.TYPE_NOTI, regist_payload(2), steps=2)
            self.later(self.send, defs.NET, defs.NET_REGIST, defs.TYPE_NOTI, regist_payload(3), steps=2)
            self.later(self.send, defs.DISP, defs.DISP_RSSI_INFO, defs.TYPE_NOTI, rssi_payload(), steps=3)
        else:
            self.later(self.send, defs.PWR, defs.PWR_PHONE_STATE, defs.TYPE_NOTI, b"\x01")

    # SEC
    def _h_05_01(self, f):
        if f.type == defs.TYPE_GET:
            self.resp(f, bytes(self.pin_status))
        else:
            self.gen(f)
            self.pin_status = (0x00, 0x00)
            self.later(self.send, defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_NOTI, b"\x00\x00")

    def _h_05_08(self, f):
        self.resp(f, bytes([0x01, f.payload[1], 0x01, 3]))

    # NET
    def _h_08_05(self, f):
        self.resp(f, regist_payload(f.payload[1]))

    def _h_08_03(self, f):
        self.resp(f, serving_payload())

    def _h_08_04(self, f):
        self.resp(f, bytes([1, 2]) + FAKE_PLMN + bytes([0x21, 0, 0]))

    # DISP
    def _h_07_01(self, f):
        self.resp(f, icon_payload())

    # MISC
    def _h_0a_03(self, f):
        self.resp(f, bytes([0x01, len(FAKE_IMEI)]) + FAKE_IMEI)

    def _h_0a_02(self, f):
        self.resp(f, bytes([len(FAKE_IMSI)]) + FAKE_IMSI)

    def _h_0a_01(self, f):
        self.resp(f, bytes([0x0F]) + b"FAKE-SW-1".ljust(32, b"\0") + b"FAKE-HW".ljust(32, b"\0") + bytes(64))

    # SMS
    def _h_04_0a(self, f):
        self.resp(f, FAKE_SMSC_FIELD)

    def _h_04_01(self, f):
        self.gen(f)  # OK first, the RESP with the message reference follows
        self.sms_ref = (self.sms_ref + 1) & 0xFF
        self.later(self.resp, f, struct.pack("<BHBB", 0x02, 0x0000, self.sms_ref, 0))

    # CALL
    def _h_02_01(self, f):
        self.gen(f)
        cid = self.next_call_id
        self.next_call_id += 1
        self.calls[cid] = {"state": 3, "direction": "out", "number": "+" + f.payload[5:5 + f.payload[3]].decode()}
        self.later(self._call_status, cid, 1)
        self.later(self._call_status, cid, 5, steps=2)
        self.later(self._connect, cid, steps=4)

    def _connect(self, cid):
        if cid in self.calls:
            self.calls[cid]["state"] = 1
            self._call_status(cid, 3)
            if self.send_clock:
                self.later(self.send, defs.SND, defs.SND_CLOCK_CTRL, defs.TYPE_NOTI, b"\x01")

    def _h_02_04(self, f):
        self.gen(f)
        for cid, c in self.calls.items():
            if c["direction"] == "in" and c["state"] == 5:
                self.later(self._connect, cid)

    def _h_02_03(self, f):
        self.gen(f)
        for cid in list(self.calls):
            self.later(self.remote_hangup, cid)

    def _h_0c_07(self, f):
        self.gen(f)
        if f.payload[0] == 3:
            self.later(self.remote_hangup, f.payload[1])

    def _h_02_06(self, f):
        body = bytes([len(self.calls)])
        for cid, c in sorted(self.calls.items()):
            num = c["number"].lstrip("+").encode()
            body += struct.pack("<HBBBBBB", 0x0100, cid, 1 if c["direction"] == "out" else 0,
                                c["state"], 0, len(num), 0x11 if c["number"].startswith("+") else 0x21) + num
        self.resp(f, body)

    # SND
    def _h_09_09(self, f):
        self.gen(f)
        if f.payload[:1] == b"\x00":
            self.later(self.send, defs.SND, defs.SND_CLOCK_CTRL, defs.TYPE_NOTI, b"\x02")

    # GPRS
    def _h_0d_04(self, f):
        self.gen(f)
        action, cid = f.payload[0], f.payload[1]
        if action == 1 and self.pdp_refuse:
            self.later(self.send, defs.GPRS, defs.GPRS_CALL_STATUS, defs.TYPE_NOTI,
                       bytes([cid, 3, self.pdp_refuse.pop(0), 0]))
        elif action == 1:
            self.pdp_up.add(cid)
            self.later(self.send, defs.GPRS, defs.GPRS_CALL_STATUS, defs.TYPE_NOTI, bytes([cid, 1, 0, 0]))
            self.later(self.send, defs.GPRS, defs.GPRS_IP_CONFIGURATION, defs.TYPE_NOTI,
                       ip_config_payload(cid, self.pdp_mtu), steps=2)
        else:
            self.pdp_up.discard(cid)
            self.later(self.send, defs.GPRS, defs.GPRS_CALL_STATUS, defs.TYPE_NOTI, bytes([cid, 0, 0, 0]))


def _standalone(argv):
    import argparse
    import tty
    from shannond.loop import SelectorLoop
    from shannond.rfs import HDR
    p = argparse.ArgumentParser(description="fake Shannon CP on two ptys (MOCK)")
    p.add_argument("--dir", required=True)
    p.add_argument("--boot-delay", type=float, default=0.5)
    args = p.parse_args(argv)
    os.makedirs(args.dir, exist_ok=True)
    loop = SelectorLoop()
    links = {}
    masters = {}
    slaves = []
    for name in ("ipc", "rfs"):
        master, slave = os.openpty()
        tty.setraw(slave)
        slaves.append(slave)  # keep it open: raw mode stays, no hang-up before the daemon opens it
        link = os.path.join(args.dir, name)
        if os.path.lexists(link):
            os.unlink(link)
        os.symlink(os.ttyname(slave), link)
        links[name] = link
        masters[name] = master
    fake = FakeModem(loop, masters["ipc"], masters["rfs"], stream=True)
    print("fake modem ready: ipc=%s rfs=%s" % (links["ipc"], links["rfs"]), flush=True)

    def boot():
        fake.boot()
        fake.send_rfs(HDR.pack(14, 0x01, 0x21) + struct.pack("<II", 0, 16))  # NV_READ_ITEM 16 bytes

    loop.call_later(args.boot_delay, boot)
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_standalone(sys.argv[1:]))
