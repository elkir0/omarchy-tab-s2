#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the real source-family selector and retained legacy archive."""
from pathlib import Path
import runpy

package = Path(__file__).resolve().parent.parent
module = runpy.run_path(str(package / 'bin/omamobile-omarchy-patches'))
select = module['default_series']

assert select('/fixture', [('omarchy', '4.0.6-2', None)]).endswith('/legacy-4.0.6')
assert select('/fixture', [('omarchy', '4.5.0-3', None)]).endswith('/patches')
try:
    select('/fixture', [('omarchy', '4.6.0-1', None)])
except module['Failure']:
    pass
else:
    raise AssertionError('unsupported source family accepted')

# Pinned, not counted (L-637): a new legacy fix adds a name here instead of
# breaking a literal count that every other PR also bumps. The tablet drops
# seven phone-only patches from each family (0012, 0014, 0016, 0020, 0021,
# 0022, 0029) and adds two of its own (9000/9001); the SM-T715 build adds one
# more to the 4.5 family (9002-t715-lock-blank-through-keys). Upstream 0.1.51
# ships 29 legacy and 31 4.5 patches: the tablet keeps 29 - 7 + 2 = 24 and
# 31 - 7 + 3 = 27.
legacy = {p.name[:4] for p in (package / 'legacy-4.0.6').glob('0*.patch')}
retained = {'0001', '0003', '0005', '0006', '0007', '0008', '0009', '0010',
            '0011', '0013', '0015', '0017', '0018', '0019', '0023', '0024',
            '0025', '0026', '0027', '0028', '0030'}
missing = retained - legacy
assert not missing, 'tablet legacy archive lost %s' % sorted(missing)
assert (package / 'legacy-4.0.6/bridge-4.0.4-menu-first-frame.patch').is_file()
assert len(list((package / 'legacy-4.0.6').glob('*.patch'))) == 24
assert len(list((package / 'patches').glob('*.patch'))) == 27
print('PASS: actual selector rejects unsupported families; tablet series sizes hold')
