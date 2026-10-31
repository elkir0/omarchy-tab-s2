# SPDX-License-Identifier: GPL-2.0-or-later
"""shannond: userspace owner of the Shannon SS333 modem (Samsung IPC 4.1 + RFS).

Modules:
    loop      event-loop abstraction (GLib in production, selectors in tests)
    ipc       FMT framing, sequencing, request/answer matching
    defs      protocol constants
    messages  payload codecs (sizes from the IPC 4.1 catalogue)
    sms_pdu   SMS-SUBMIT / SMS-DELIVER PDU codec
    rfs       RFS server, "observe" mode (sandboxed, nothing persists)
    core      ModemCore: state, events, commands (API for the MM facade)
    netcfg    rmnet configuration (external or iproute2)
    control   JSON-lines control socket
    daemon    command-line entry point (python3 -m shannond)
    ctl       shannonctl client
"""

__version__ = "0.1.0"
