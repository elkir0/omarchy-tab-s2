# Licensing

The project's own code and documentation are under the GNU General Public License, version 2 or
later (`LICENSE`), unless a file says otherwise. A file's SPDX header wins over this notice.

| Part | License |
|---|---|
| `kernel/patches/` | GPL-2.0, as the Linux kernel; each patch keeps its authors' notices |
| `kernel/patches/t715-modem/`, the `modem_v1` import | Samsung's driver sources for the 3.10 kernel, under the GPL, with their original headers |
| `modem/` | GPL-2.0-or-later |
| `image/pkg/omamobile-*`, `image/pkg/omaphone`, `image/pkg/omamessages`, `image/pkg/omatel-agent` | build recipes and patches for omarchy-mobile (MIT, Copyright (c) 2026 Derek Ross), some with GPL-3.0-or-later parts |
| `image/rootfs/overlay/usr/local/bin/t715-keys`, and other files forked from omarchy-mobile | MIT, Copyright (c) 2026 Derek Ross, as their headers say |
| `image/pkg/hyprgraphics` | BSD-3-Clause, as upstream |
| `image/rootfs/overlay/usr/share/t715-omarchy/squeekboard/` | GPL-3.0-or-later, from squeekboard |

## What is not here

No Samsung firmware, blob or decompiled code is in this repository. The build takes what it needs
from your own tablet, and those files stay on your machine:

- the Wi-Fi NVRAM and the Bluetooth patch RAM, from `/system`;
- the modem's BOOT and MAIN images, read from the RADIO partition at run time, on the tablet;
- the NV data, read from EFS, on the tablet.

For the same reason this project publishes no root image: one would carry Samsung's two files.

The notes in `research/` and `docs/hardware/` describe what we observed, for interoperability, by
reading public sources and by static analysis of Samsung's binaries, decompilation included:
addresses, formats, message identifiers, and short strings quoted as identifiers. They reproduce
none of Samsung's code.

Omarchy, Samsung and Galaxy are their owners' names. This project is not affiliated with them.
