#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Crash the running CP on purpose, for the crash-recovery gate (G12b) only.

    cp-force-crash.py --yes

Sends IOCTL_MODEM_FORCE_CRASH_EXIT (0x6F34) on /dev/umts_boot0: the kernel
stops the link and raises AP_DUMP_INT, the CP answers with CRASH_EXIT (or the
10 s ack timer fires), and the holders see POLLHUP. shannon-loader then does
its silent reset (MODEM_OFF and a full boot). Refuses unless the CP is ONLINE.
Never use IOCTL_MODEM_CP_UPLOAD: it is not this request, and it panics the AP.
"""
import fcntl
import os
import sys

IOCTL_MODEM_FORCE_CRASH_EXIT = 0x6F34
IOCTL_MODEM_STATUS = 0x6F27
STATE_ONLINE = 4


def main():
    if sys.argv[1:] != ["--yes"]:
        sys.exit(__doc__.strip())
    fd = os.open("/dev/umts_boot0", os.O_RDWR | os.O_CLOEXEC)
    try:
        state = fcntl.ioctl(fd, IOCTL_MODEM_STATUS)
        if state != STATE_ONLINE:
            sys.exit("CP state %d, not ONLINE (4): refused" % state)
        fcntl.ioctl(fd, IOCTL_MODEM_FORCE_CRASH_EXIT)
        print("FORCE_CRASH_EXIT sent")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
