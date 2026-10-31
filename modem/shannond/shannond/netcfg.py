# SPDX-License-Identifier: GPL-2.0-or-later
"""rmnet configuration after a PDP context comes up (SYNTHESIS §2.14, D7).

Mode ``external`` (default): publish address/prefix/DNS/MTU (event + JSON file
under /run/shannond/data/) for the ModemManager facade / NetworkManager, and
touch nothing.  Mode ``iproute2`` (``--configure-ip``): bring rmnet(cid-1) up,
add the /32 address, set the MTU and add a default route with a chosen metric
(700 by default, above NetworkManager's Wi-Fi 600, so Wi-Fi stays preferred).
DNS is only pushed to systemd-resolved with ``--configure-dns``.
"""

import json
import logging
import os
import shutil
import subprocess

log = logging.getLogger("shannond.netcfg")


def interface_for_cid(cid):
    """cid 1..4 -> rmnet0..3 (GsmDataCallManager::CreateDataCallList rule)."""
    return "rmnet%d" % (cid - 1)


class NetConfig:
    def __init__(self, mode="external", state_dir="/run/shannond/data", route_metric=700,
                 default_route=True, configure_dns=False, runner=None):
        if mode not in ("external", "iproute2"):
            raise ValueError("mode must be external or iproute2")
        self.mode = mode
        self.state_dir = state_dir
        self.route_metric = route_metric
        self.default_route = default_route
        self.configure_dns = configure_dns
        self.runner = runner or self._run
        self.commands = []  # history (tests)

    def _run(self, argv):
        self.commands.append(list(argv))
        exe = shutil.which(argv[0])
        if exe is None:
            raise OSError("%s not found" % argv[0])
        res = subprocess.run([exe] + list(argv[1:]), stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, timeout=10)
        if res.returncode != 0:
            raise OSError("%s failed: %s" % (" ".join(argv[:4]), res.stderr.strip()[:200]))
        return res.stdout

    def _publish(self, iface, info):
        if not self.state_dir:
            return
        try:
            os.makedirs(self.state_dir, mode=0o750, exist_ok=True)
            path = os.path.join(self.state_dir, iface + ".json")
            tmp = path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o640)
            with os.fdopen(fd, "w") as f:
                json.dump(info, f, indent=1, sort_keys=True)
            os.replace(tmp, path)
        except OSError as exc:
            log.warning("cannot publish data state for %s: %s", iface, exc)

    def _unpublish(self, iface):
        if not self.state_dir:
            return
        try:
            os.unlink(os.path.join(self.state_dir, iface + ".json"))
        except OSError:
            pass

    def up(self, iface, info):
        """info: the 'data' event dict.  Raises OSError on iproute2 failure."""
        self._publish(iface, info)
        if self.mode != "iproute2":
            return
        v4 = info.get("ipv4") or {}
        run = self.runner
        run(["ip", "link", "set", "dev", iface, "up"])
        if v4.get("mtu"):
            run(["ip", "link", "set", "dev", iface, "mtu", str(v4["mtu"])])
        run(["ip", "-4", "addr", "flush", "dev", iface, "scope", "global"])
        if v4.get("address"):
            run(["ip", "-4", "addr", "add", "%s/%d" % (v4["address"], v4.get("prefix", 32)), "dev", iface])
            if self.default_route:
                run(["ip", "-4", "route", "replace", "default", "dev", iface, "metric", str(self.route_metric)])
        if self.configure_dns and v4.get("dns"):
            try:
                run(["resolvectl", "dns", iface] + list(v4["dns"]))
            except OSError as exc:
                log.warning("resolvectl failed: %s", exc)
        log.info("%s configured with iproute2 (metric %d)", iface, self.route_metric)

    def down(self, iface):
        self._unpublish(iface)
        if self.mode != "iproute2":
            return
        for argv in (["ip", "-4", "route", "del", "default", "dev", iface],
                     ["ip", "-4", "addr", "flush", "dev", iface, "scope", "global"],
                     ["ip", "link", "set", "dev", iface, "down"]):
            try:
                self.runner(argv)
            except OSError as exc:
                log.debug("%s", exc)
